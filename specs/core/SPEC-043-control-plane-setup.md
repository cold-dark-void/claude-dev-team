# SPEC-043: /setup control-plane — One Command Build, Install, Enable, Verify

**Status**: ACTIVE
**Category**: core
**Created**: 2026-11-19

**Covers**: `commands/setup.md`, `docs/commands/setup.md`, `skills/control-plane/SKILL.md`, `skills/control-plane/setup.sh`, `skills/control-plane/preflight.sh`, `skills/control-plane/units.sh`, `skills/control-plane/test.sh`, `skills/control-plane/test-units.sh`, `skills/control-plane/test-preflight.sh`, `skills/lib/record-status.sh`, `skills/doctor/checks/controlplane.sh`, `skills/doctor/checks/lib.sh`, `skills/doctor/checks/report.sh`, `docs/internal/control-plane/native-runner.md`, `control-plane/README.md`

---

## Overview

The phase-1 control plane (CDT-628) ships as source and a build recipe spread
over `control-plane/build.sh`, `control-plane/README.md`, and
`docs/internal/control-plane/native-runner.md`. No install path exists. Today
an operator assembles the machine by hand: build inside the approved image,
place binaries, write a systemd user unit, enable it, and check the result —
each step a separate doc.

`/setup control-plane` collapses this into one idempotent command. One run
preflights the node, builds the two phase-1 binaries inside the G-02-approved
Go image, installs them under `$HOME`, installs and enables the chiefd systemd
**user** unit, and verifies with a PASS/WARN/FAIL table. The node agent
installs as a CLI that is invoked by path, never as a unit (M5). Flags add
`--status` (read-only table) and `--uninstall` (Linux-side removal). `/doctor`
gains one read-only row. Linux with systemd is the only supported platform;
WSL2 nodes are supported when systemd is on. macOS is out of scope (CDT-631).

The command writes nothing the control plane owns. The service keeps its
records (record-ownership rows 12/14/15); the plugin keeps no copy of them.
The service keeps its journal CLI name; the plugin never puts it on PATH.

## Boundaries

- **SPEC-022 (/doctor)** owns the doctor battery, its severity semantics, and
  its closed `--fix` allowlist. This spec adds one check group through the
  SPEC-022 extension rule (a check function, not a renderer change). The new
  check is WARN-never-FAIL; `--fix` never repairs it.
- **`skills/lib/record-status.sh`** owns the record-and-render pair the M6
  table and the `/doctor` battery share (the plan's Copy-extract extract,
  SPEC-033 M14). The M6 rows and the footer render there, once; SPEC-022 M5's
  output is preserved byte-identical.
- **ADR 0001 (journal engine)** owns the plugin↔service boundary — files and
  CLI calls only. The setup sub crosses it exactly twice: it runs
  `control-plane/cmd/journalctl` and `control-plane/cmd/node-agent` by path —
  the journal CLI by its `control-plane/dist/` path, and the M6 binary row the
  installed agent by its `%h/.local/bin/` path (M3). Neither call goes through
  `PATH`, and it never opens the journal DB itself.
- **record-ownership.md** owns the records. Row 14 (`node.json`, runner
  selection) has no plugin writer — this sub reads it and never writes it.
  Row 12 (the run journal) and row 15 (the page record) are untouched by
  install and uninstall.
- **SPEC-030 R4 / SPEC-010 S7** carve `control-plane/` out of discovery, the
  smoke harness, and release gates. The setup sub is plugin product; the
  service directory it builds stays carved out.
- **SPEC-021** gates all new bash through skill-lint.
- **SPEC-002 + SPEC-033 (arc)** own the version pair. A new command sub is a
  minor-class change; during the arc the release rides `2.0.0-pre.N`.
- **The G-02 approval record** (`node-agent-build-probe.md` § "The Go build
  image — approval record") owns the approved image. This spec cites the
  approved digest and never approves a new one.

## MUST

- **M1 — One dispatch, three modes.** `/setup control-plane` is a known sub of
  the `/setup` dispatcher. Modes: bare install (preflight → build → install →
  enable → verify table), `--status` (the verify table alone, zero writes, no
  build), `--uninstall` (M9). Bare/unknown `/setup` behavior stays as
  SPEC-005 defines it: usage only, zero side effects. The journal CLI creates
  its database when it opens a new one, so `--status` runs the probe state read
  only when the journal file already exists; on a node with no journal the
  probe row is a WARN that names the path and the read never runs.
- **M2 — Ordered preflight, fail-closed.** Preflight runs before any side
  effect, in this order, and aborts non-zero on the first failure with the
  check name and a fix line: (a) platform — Linux or WSL2 (`uname -r` names
  `microsoft-standard-WSL2`); (b) systemd user manager usable
  (`systemctl --user is-system-running` answers `running` or `degraded`);
  (c) when WSL2, `/etc/wsl.conf` carries `[boot] systemd=true`; (d) checkout —
  `control-plane/go.mod` exists under `$MROOT`; (e) `docker` on PATH and
  reachable; (f) the approved image pin — the only acceptable reference is
  `docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea`;
  a different tag or digest aborts before any pull or build; (g) runner
  selection valid — `node.json` key `runner` or `$DEVTEAM_RUNNER` resolves in
  the closed set `native|container`; an absent selection resolves to `native`
  for the verify-table report and for the M11 probe start (the agent's own
  fail-closed read starts no run on a node with no selection). Reporting is
  unchanged from the read-only rule: resolution never writes `node.json`
  or `$DEVTEAM_RUNNER`. Preflight failure leaves zero partial state: no
  binaries, no units, no journal rows.
- **M3 — Never sudo, everything under `$HOME`.** The command never invokes
  `sudo`, `su`, or `pkexec`. Every write target is user-writable: binaries to
  `%h/.local/bin/` (`node-agent`, `chiefd`, mode `755`), the unit to
  `%h/.config/systemd/user/` (`dev-team-chiefd.service`, mode `644`).
  Preflight MUST refuse to run when a target is not writable by the
  invoking user.
- **M4 — Build inside the approved image only.** The build runs
  `docker run --user <uid>:<gid>` with the pinned digest of M2(f), host
  `GOOS`/`GOARCH`, `CGO_ENABLED=0`, caches outside the mount
  (`GOCACHE`/`GOMODCACHE`/`HOME` under container `/tmp`). Outputs land in
  `control-plane/dist/` (git-ignored). The setup sub MAY reuse
  `control-plane/build.sh` for the node agent; chiefd builds the same way.
- **M5 — One unit and its enablement.** The machine supervises chiefd only.
  The unit: `ExecStart=%h/.local/bin/chiefd --addr 127.0.0.1:8090` (the
  service's real CLI; chiefd binds `127.0.0.1:8090` by default),
  `Restart=on-failure`, `RestartSec=2s`, `WantedBy=default.target`, and
  journald capture by default. The unit MUST also carry the service env the
  install resolved (CDT-666): `WorkingDirectory=<the checkout root>`,
  `Environment="DEVTEAM_MROOT=<the checkout root>"`, and
  `Environment="PATH=<each user CLI dir that exists at install>:<the systemd
  user-manager defaults>"` — `chiefd` resolves its journal and its plugin root
  from `$DEVTEAM_MROOT` (else the git parent of `$HOME`, which is not a repo),
  and the native runner spawns the host CLI by name, so an unstamped unit
  serves an empty journal beside the project's and refuses every spawn with
  `executable file not found in $PATH`. The PATH is probed, never hardcoded: a
  user CLI dir that does not exist is not stamped, so the value degrades to the
  systemd defaults. Install writes the unit file, then
  `systemctl --user daemon-reload`, then
  `systemctl --user enable --now dev-team-chiefd.service`. Enablement never
  widens the chiefd bind beyond loopback. Install MUST NOT write a unit for
  the node agent in phase 1: the agent has no long-lived verb (its verbs are
  `start`, `stop`, `status`, `steer`, `status-node`, so a supervised
  `ExecStart` exits at once and restart-loops), so the agent is invoked by
  path per run and is never supervised. The daemon verb that restores
  reboot-time supervision of the agent stays a phase-4 concern (CDT-631) and
  is recorded as the follow-up in
  `docs/internal/control-plane/native-runner.md` § "CDT-644". Reboot-time
  supervision of the work needs no such verb: SPEC-044 (CDT-660) lands
  chiefd's takeover scan, so a restarted chiefd re-supervises the in-flight
  runs in its own process (SPEC-044 OQ7), and the linger step that lets the
  unit run before login stays the operator step of M10. Install
  MUST also stop, disable, and remove a `dev-team-node-agent.service` unit an
  earlier install left behind: it stays enabled, its supervised binary has no
  unit to run it, and `Restart=on-failure` restart-loops it. Every purge of
  such a unit — install-side and uninstall-side — is followed by
  `systemctl --user reset-failed`, because the purged unit's `failed` state is
  what keeps the manager answering `degraded`. Install writes the unit file it
  owns and MUST NOT touch a drop-in directory
  (`dev-team-chiefd.service.d/override.conf`): an override an operator wrote is
  theirs and survives every later install (CDT-666).
- **M6 — Verify table.** One table, one row per check, PASS/WARN/FAIL, a
  `N pass / N warn / N fail / N skip` footer. Rows: chiefd answers on
  `127.0.0.1:8090` (an HTTP GET against the `/v1` API); the chiefd unit
  `is-active` = active; the node agent binary row — the installed
  `%h/.local/bin/node-agent` binary answers `status-node` with exit `0` (a
  binary row: there is no node-agent unit, M5). The row reads the installed
  binary, never the `control-plane/dist/` build output; a node that has the
  build output and no installed binary is a WARN that names the install path;
  the probe row — the probe run's journal
  state reads `completed` (T0 § Q1a: `node-agent status` exits 0 even for a
  run id with no journal rows, so the row MUST gate on the journal state,
  never on the status exit code alone; with no journal file the row is a WARN
  `no journal` and the read is skipped (M1); the resolved runner selection
  (AC6, read-only); the linger row (M10); the served-journal row — the
  `/v1/runs` board names the fixed probe run, so the service serves
  `$MROOT/.claude/runs/run.db` and not the `$HOME` store an unstamped unit
  resolves (M5, CDT-666); the service-env row — `systemctl --user show
  dev-team-chiefd.service -p Environment` carries `DEVTEAM_MROOT` for the
  checkout and a PATH that resolves the node's host CLI (M5, CDT-666); the
  WSL2 rows (M8). Fix-it lines
  accompany every WARN and FAIL.
- **M7 — Exit codes (lifted from /doctor's scheme).** `0` = only PASS/WARN
  rows; `2` = at least one FAIL; `64` = usage error; `63` = unsupported
  platform (M2a–c fail, or macOS). The codes reuse `/doctor`'s implemented
  scheme; `63` is the one distinct code this spec reserves for the
  unsupported/failed-environment-shape preflight (M2a–c fail, macOS, or the
  M2(d) checkout-absent failure per AC8).
- **M8 — WSL2 auto-start rows are WARN-level.** Three rows on WSL2: (a)
  `systemd=true` in `/etc/wsl.conf` — verifiable inside WSL; (b) the Windows
  Task Scheduler logon task (`wsl.exe` at logon) — WARN with the exact
  operator step; (c) the `.wslconfig` idle-shutdown setting — the distro key
  `[general] instanceIdleTimeout` (`-1` disables auto-shutdown; vendor-
  documented on all supported Windows versions and the primary step on
  Windows 10), with `[wsl2] vmIdleTimeout` (Windows 11 only per
  Microsoft's `.wslconfig` table; its `-1` disable value is vendor-
  undocumented) named second — WARN with the exact operator step. (b) and
  (c) can never verify from inside WSL — the file lives on the Windows side
  (`%UserProfile%\.wslconfig`); the operator confirms them out of band.
  Post-reboot proof is CDT-659 scope; this spec MUST NOT attempt it.
- **M9 — `--uninstall` is Linux-side only and reversible.** It stops and
  disables the chiefd unit, removes the unit file and both binaries (the
  `node-agent` binary included — it is an installed CLI, M3) from their
  install paths, and removes a `dev-team-node-agent.service` unit file an
  earlier install left behind (M5), runs `daemon-reload`, then
  `systemctl --user reset-failed` so the user manager drops the failed-unit
  state a stopped unit leaves behind, exits `0`, and never touches Windows —
  it prints the Windows operator steps (remove the Task Scheduler task; the
  `.wslconfig`/`wsl.conf` lines stay or go, operator's choice) instead. The
  journal DB is never read, written, moved, or deleted; a `--status` after
  uninstall still reads it. A subsequent bare install reaches the M6 table.
- **M10 — Linger never self-serves.** The verify table carries a linger row
  from `loginctl show-user "$USER" -p Linger`. `Linger=no` → the row prints
  the exact command `sudo loginctl enable-linger "$USER"` and waits for the
  operator's documented continue/skip answer (documented in the SKILL.md).
  The command itself never executes sudo. A later re-run reports PASS once
  linger is on. Linger is WARN-level, never FAIL: without it the units work
  until the session ends.
- **M11 — Probe hygiene (T0 ruling Q1b: no `stop` verb).** The verify flow
  starts exactly one probe run through the node agent's `start` verb (run id
  `devteam-setup-probe`, a trivial command through `--command`) and requires
  zero leftover runner processes or containers after `start` returns — a
  completed run reaps its child and removes its pidfile (probed, § Q1b).
  The start invocation carries the M2(g) resolved selection as the
  per-invocation `$DEVTEAM_RUNNER` override, set on the child only:
  `DEVTEAM_RUNNER=<resolved> control-plane/dist/node-agent start --run-id
  devteam-setup-probe --command <no-op>`. A node with a selection passes what
  preflight resolved; a node with none passes `native` — the agent's
  fail-closed read starts no run on a node that names no runner, so an
  unoverridden probe can never pass on a fresh node. The override is an
  environment assignment on one child process: it is not a record write. The
  driver MUST NOT write `node.json` and MUST NOT set `$DEVTEAM_RUNNER` in its
  own environment or in any other process (MUST NOT below; record-ownership
  row 14).
  The `stop` verb MUST NOT run against the fixed probe id: a trivial probe
  command finishes inside `start`, so `stop` always exits 1
  (`run has no live runner process`), and if `stop` ever does stop a live
  probe it lands the fixed id in `halted:operator_halt`, which the agent
  never resumes — permanently poisoning the fixed id for every later bare
  install. The probe's journal rows ride the journal CLI. The probe invokes
  every service CLI by its `control-plane/dist/` path; nothing installs
  `journalctl` or `node-agent` onto `PATH`, and no step renames them. The
  probe proves the agent + journal + spawn path only: the probe command's
  own exit code is not journaled by the phase-1 agent (§ Q1c — a
  control-plane defect owned by a follow-up ticket). The setup sub MUST NOT
  compensate by parsing the probe command's output; it stays inside the ADR
  0001 CLI boundary.
- **M12 — Idempotent install.** A second immediate bare run exits per M7 with
  the same verdict as the first: the unit file byte-identical (write only when
  content differs), `is-enabled`/`is-active` state unchanged, the rebuild
  silent and error-free, and no duplicate probe run in the journal. The
  driver branches on the journal state, never on `node-agent start`'s
  refusal (T0 § Q1a): read
  `journalctl read --run-id devteam-setup-probe --state` first —
  `terminal: true` → skip `start` and report the recorded outcome; no rows →
  run the probe; `running` with a dead owner's lease → retry only after the
  lease expires (last heartbeat + `stall_limit_s`, 108 s at the default
  tier) and report a WARN until then, never a second `start`. Past the expiry
  the driver runs exactly one takeover `start` (T0 § Q1a: it exits `0`, writes
  `lease_acquired {"reason":"takeover"}`, and closes the pending `agent.start`
  intent — one run, not two) and reports the takeover on the probe row. A
  lease the state read cannot date counts as expired, matching
  `run.Lease.Expired`. `start` is
  never the "is the probe already done" probe — it answers only by
  refusing.

## SHOULD

- SHOULD structure preflight, build, install, and verify as small registered
  functions in one `setup.sh` so `--status` reuses the verify path unchanged.
- SHOULD print each phase banner (`preflight`, `build`, `install`, `verify`)
  so a failure names its phase.
- SHOULD resolve the plugin's own paths through `skills/plugin-dir.sh` for
  anything plugin-owned and use `$MROOT` for the checkout paths.
- SHOULD cap the probe command at a trivial no-op (`true`-equivalent) so the
  probe never depends on a host CLI's login state.

## MUST NOT

- MUST NOT invoke `sudo`, `su`, or `pkexec`, directly or through a script.
- MUST NOT reference any container image other than the M2(f) digest.
- MUST NOT write `$MROOT/.claude/dev-team/node.json`, `$DEVTEAM_RUNNER`, or
  any record-ownership row the control plane owns.
- MUST NOT touch the run journal beyond the M11 probe rows and the M11 read.
- MUST NOT widen the chiefd bind beyond loopback, or disable the loopback
  guard.
- MUST NOT place `node-agent` or `journalctl` on `PATH`, alias them, or
  rename them.
- MUST NOT install a systemd user unit for the node agent (M5): phase 1
  supervises chiefd only, and the agent is invoked by path per run.
- MUST NOT run on macOS, on Linux without a usable systemd user manager, or
  on WSL2 with systemd off — print one unsupported-platform message and exit
  `63` with zero side effects.
- MUST NOT bootstrapping anything SPEC-005 owns (memory, hooks, sandbox):
  this sub is machine provisioning only.

## Test

Bite tests in `skills/control-plane/test.sh`, hermetic (fakes for `docker`,
`systemctl`, `loginctl`; `$TMPDIR` scratch homes; no network, no real
containers). Cover: (1) preflight fail-closed per M2(a)–(g), each exit non-
zero with zero side effects; (2) the macOS exit `63`; (3) install into a
scratch `$HOME` reaches the M6 table with the chiefd unit active and the
node-agent binary row answering; (4) idempotent
second run per M12 (byte-identical unit file, unchanged state, no duplicate
probe rows); (5) `--uninstall` removes the unit and both binaries, resets
failed units, exits `0`,
preserves the journal; (6) `--status` writes nothing; (7) the exit-code
contract per M7; (8) no `sudo` token anywhere in the code paths; (9) the
only image literal is the approved digest; (10) `--command`-only probe leaves
no live runner process; (11) the probe start carries the resolved selection
as the M11 `DEVTEAM_RUNNER=<resolved>` child override — the no-selection node
shape asserts `DEVTEAM_RUNNER=native` lands on the `start` invocation;
(12) the fake `systemctl` executes the installed unit's real `ExecStart`
argv (the M5 binary plus `--addr`), so the shipped template is proven to
start clean in the shape systemd runs it — the T7 real-node blind spot;
(13) the node-agent row reads the installed `%h/.local/bin/node-agent`, and a
node with only the `control-plane/dist/` copy is a WARN naming the install
path; (14) a fresh node (no journal file) `--status` leaves the filesystem
untouched and reports the probe row as WARN `no journal` — the journal CLI
creates the database on open, so the read is skipped; (15) the M12 lease arm:
a live heartbeat is a WARN with no `start`, a heartbeat past
`last_heartbeat_ts + stall_limit_s` runs exactly one takeover `start`;
(16) the M5 env stamp: the template carries `WorkingDirectory` and
`Environment="DEVTEAM_MROOT="` for the checkout root the caller passed, the PATH
line carries the probed user CLI dirs before the systemd defaults, and it
degrades to the defaults when no user CLI dir exists (test-units);
(17) the two service-env verify rows PASS on a stamped node, FAIL after an
install and WARN under `--status` on an unstamped one, and SKIP on the M10 skip
answer; a re-install on a node with an operator drop-in keeps the drop-in
byte-identical and the unit bytes stable.
Doctor bites: uninstalled → WARN never FAIL, exit
stays at doctor's scheme. Skill-lint (SPEC-021) and docs-drift run on the
landed diff.

## Open Questions

Both questions are CLOSED by the CDT-658 T0 spike (probe 2026-11-19, host
`malcolm-pc`, WSL2 kernel `6.18.58.1-microsoft-standard-WSL2`, WSL
3.0.5.0, Windows `10.0.19045.7846`, systemd 262, docker 29.9.3). Every
command and exit code below is verbatim probe output.

Probe setup (feeds M4/M11): `bash control-plane/build.sh linux-amd64`
exited 0 and produced `control-plane/dist/node-agent-linux-amd64`; the same
pinned-image `docker run` (`go build -o dist/journalctl-linux-amd64
./cmd/journalctl`) exited 0. Both probes ran hermetically with
`DEVTEAM_MROOT`, `DEVTEAM_RUN_DB`, and `DEVTEAM_RUNNER=native` pointed at a
`mktemp -d "${TMPDIR:-/tmp}/cdt658t0.XXXXXX"` scratch, so the shared
`$MROOT/.claude/runs/run.db` was never created. The agent's own paths are
`$MROOT/.claude/runs/run.db` (journal) and
`$MROOT/.claude/runs/agent/<run-id>.pid` (pidfile) — from a worktree,
`$MROOT` is the main checkout, so the probe writes the shared store by
design.

### Q1 (M12 / AC2) — CLOSED: a re-`start` on a completed run REFUSES (exit 1), writes nothing, spawns no duplicate

| Probe | Command (from the checkout root) | rc | Output |
|---|---|---|---|
| first probe run | `node-agent start --run-id devteam-setup-probe --command true` | 0 | `ok`; 6 journal events, last `run_completed {"result":{"exit_code":0}}` |
| status read | `node-agent status --run-id devteam-setup-probe` | 0 | `"state": "completed"` |
| **re-`start`** | `node-agent start --run-id devteam-setup-probe --command true` | **1** | `node-agent start: journal: run is terminal: run devteam-setup-probe is completed` |
| journal after re-`start` | `journalctl read --run-id devteam-setup-probe --events` | 0 | 6 events before, 6 after — zero rows written, no second spawn, no new pid |

`start` is foreground and supervises the trivial command to completion, so
the run is terminal by the time `start` returns. The refusal is
`journal.ErrTerminalState` from `run.Machine.Claim`
(`control-plane/run/machine.go:138` — `if st.IsTerminal()`). The driver's
no-duplicate branch is therefore: read the journal state first
(`journalctl read --run-id devteam-setup-probe --state`, key `terminal`),
and on `terminal: true` skip `start` and report the recorded outcome.
`node-agent start` is never the "is the probe already done" probe — it
answers only by refusing.

### Q1a — Journal states the driver must branch on (all probed)

| State of the fixed run id | `start` rc / stderr | Driver branch |
|---|---|---|
| no rows (unknown id) | 0, spawns and completes | run the probe |
| `completed` / terminal | 1, `journal: run is terminal: …` | re-use the recorded outcome (M12 path) |
| `running`, lease held by a dead owner | 1, `journal: lease held by another owner: … (token 1, heartbeat …, limit 108s)` | retry only after the lease expires (last heartbeat + `stall_limit_s`, 108 s at the default tier; takeover rule `control-plane/run/lease.go:101`). After expiry the re-`start` exits 0 and writes `lease_acquired {"reason":"takeover"}` + closes the pending `agent.start` intent — one run, not two (probed on a run whose spawn had failed) |
| `halted:operator_halt` (`terminal: false`) | 1, `agent: run is in a halt state the agent does not resume: halted:operator_halt` | **dead end** — see Q1b |
| spawn failure (`--command definitely-not-a-command`) | 1, `agent: spawn …: executable file not found in $PATH`; the run is left `running` with a PENDING `agent.start` intent and a held lease | the fixed id is poisoned for ~108 s; an immediate idempotent re-run FAILS, it is not a PASS |

`node-agent status` exits 0 in every case, including an id that has no
journal rows at all (`status --run-id cdt658t0-nope` → rc 0,
`"state": "new"`). AC1's "node agent status verb returns 0" is satisfied by
a run that never existed; the verify row MUST gate on the journal state,
never on the status exit code alone.

### Q1b — M11's `stop` verb is a defect for the fixed probe id

| Probe | Command | rc | Result |
|---|---|---|---|
| stop a live run | `node-agent stop --run-id cdt658t0-live` (started with `--command sleep --arg 30`) | 0 | `agent.stop` intent+outcome, then `run_halted {"reason":"operator_halt"}`; `terminal: false`; child killed, pidfile removed, no leftover process (AC13 hygiene holds) |
| stop a completed run | `node-agent stop --run-id devteam-setup-probe` | 1 | `agent: run has no live runner process: devteam-setup-probe is completed` |
| re-`start` a stopped run | `node-agent start --run-id cdt658t0-live --command true` | 1 | `agent: run is in a halt state the agent does not resume: halted:operator_halt` |

Consequence for M11/M12 as written: a trivial probe command finishes inside
`start`, so the M11 `stop` step always exits 1; and if it ever does stop a
live probe, it lands the fixed id in `halted:operator_halt`, which the agent
never resumes — every later bare install then fails its probe with exit 1.
The probe hygiene check AC13 needs is "no leftover runner process", which
the completion path already gives (pidfile removed, child reaped).

**Ruling (TL, 2026-11-19): ACCEPTED.** The `stop` verb is dropped from the
probe flow. M11's hygiene step reads "verify no leftover runner process"
after `start` returns — not "stop the run". M11's fixed run id and AC13's
hygiene check stay. AC13's "stops it" wording is amended to match (the PM
routed the ruling here). Never call `node-agent stop` against
`devteam-setup-probe`: a live-probe stop permanently poisons the fixed id.

### Q1c — The probe cannot see the probe command's exit code (control-plane defect)

`node-agent start --run-id cdt658t0-x3 --command sh --arg -c --arg "exit 3"`
exited 0 and journaled `run_completed {"result":{"exit_code":0}}`. Cause:
the native runner closes its done channel without sending
(`control-plane/agent/runner.go:120-126`), so `supervise`'s
`case exitErr := <-proc.Done()` (`control-plane/agent/agent.go:437`) reads
`nil`, `exitCode(nil) == 0`, and `runnerExit` takes the code-0 `Complete`
branch (`control-plane/agent/agent.go:455-462`). The journal therefore
cannot report a failed probe command: the probe proves the agent + journal
+ spawn path only. The fix belongs to the control plane (a follow-up ticket),
not to SPEC-043 — the setup sub stays inside the ADR 0001 CLI boundary and
MUST NOT compensate by parsing the probe command's own output.

**Ruling (TL, 2026-11-19): CONFIRMED follow-up ticket.** SPEC-043's probe
verifies the agent + journal + spawn path; the probe command's own exit
code is out of scope for the setup sub. File the agent-side fix against the
control plane so the journal carries the runner's real exit code.

### Q2 (AC10) — CLOSED: linger output shape on this host

`loginctl show-user "$USER" -p Linger` → `Linger=no`, rc 0 — one line,
`Key=value`, no leading whitespace, no trailing blank line. A uid is
accepted in place of the name (`loginctl show-user 1000 -p Linger` →
`Linger=no`, rc 0). `-p Linger --value` → `no`, rc 0. Parsed value on this
node today: `no` (AC10's WARN row is live on this host).

### Q3 (AC7c / M8c) — CLOSED with a scope correction: `vmIdleTimeout` is the VM key, `instanceIdleTimeout` is the distro key

Vendor evidence — Microsoft Learn, "Advanced settings configuration in WSL"
(`https://learn.microsoft.com/en-us/windows/wsl/wsl-config`, page dated
2026-10-16):

- `[wsl2] vmIdleTimeout` | number | default `60000` | "The number of
  milliseconds that a VM is idle, before it is shut down." Footnote: "Only
  available on Windows 11."
- `[general] instanceIdleTimeout` | number | default `15000` | "The number
  of milliseconds that a distro is idle, before it is shut down. Set to `-1`
  to disable auto shutdown."
- Introduction of the VM key — WSL release notes, Build 20190: "Add
  `%userprofile%\.wslconfig` option to control the VM idle timeout
  (`wsl2.vmIdleTimeout=<time_in_ms>`)".

Answers: `vmIdleTimeout` is the right key NAME for the VM idle timer, and it
is real. It does NOT keep a running distribution alive — its timer starts
when the VM goes idle, i.e. after every distro has already stopped. The key
that prevents automatic idle shutdown of the distro that hosts systemd, the
user manager, and the node agent is the documented
`[general] instanceIdleTimeout=-1`. So AC7c's single-key framing is
incomplete: the operator step must name both keys.

Values: milliseconds (number). The vendor table documents `-1` only for
`instanceIdleTimeout`; `-1` for `vmIdleTimeout` is widely reported to
disable VM auto-shutdown but is NOT in Microsoft's table — flag it to the
operator as vendor-undocumented. The table gives no `-1`/`0` row for
`vmIdleTimeout`.

Host facts: `wsl.exe --version` → WSL 3.0.5.0 on Windows `10.0.19045.7846`
(Windows 10, not 11 — the table's Windows 11 footnote limits
`vmIdleTimeout` here, so the vendor-documented key on this node is
`instanceIdleTimeout`). `.wslconfig` lives on the Windows side at
`%UserProfile%\.wslconfig`; from inside WSL it is
`/mnt/c/Users/<user>/.wslconfig` (this host: 21 bytes, CRLF-terminated,
`[wsl2]` + `memory=64GB`). It is not under `$HOME`, so the AC7c row is
best-effort from inside WSL and stays WARN — matching M8's "can never verify
from inside WSL" rule. AC7a is verifiable: `/etc/wsl.conf` on this host
carries `[boot] systemd=true` (rc 0), and `systemctl --user
is-system-running` → `running` (rc 0).

## Validation

- Spec reviewed and promoted to ACTIVE
- Fresh install reaches the AC1 table on this host (Linux/WSL2, systemd on)
- Idempotent re-run per AC2 proven byte-identical (unit file diff-clean)
- Uninstall → manager reset-failed clean → journal present → reinstall
  reaches PASS (AC3)
- Exit-code contract (`0`/`2`/`63`/`64`) verified end-to-end (AC12)
- Preflight failure paths each leave a snapshot-diff-clean tree (AC9)
- Skill-lint (SPEC-021) and docs-drift green on the landed diff

## Version History

| Date | Change |
|------|--------|
| 2026-11-25 | CDT-666 (defect fix, plugin-side): M5 gains the service-env stamp — the chiefd unit carries `WorkingDirectory` and `Environment="DEVTEAM_MROOT="` for the checkout root the install resolved, plus `Environment="PATH="` built from the user CLI dirs that exist at install and the systemd user defaults, and the install never writes an operator drop-in directory. The install wrote no env before, so `chiefd` resolved `$HOME` (not a repo): it served an empty journal beside the project's, refused every plugin-root route, and the native spawn died on `executable file not found in $PATH` — the CDT-659 phase-1 validation needed a hand-written `dev-team-chiefd.service.d/override.conf` to route anything. M6 gains the two rows that prove the stamp (`controlplane.chiefd.journal`, `controlplane.chiefd.env`); Test items (16)–(17) bind them. No AC text changed: AC1's "every row PASS" now covers the two new rows. |
| 2026-11-22 | CDT-620 T4 (macos lane red): M12's probe-lease contract is unchanged — the takeover was a date-parsing defect in `skills/control-plane/setup.sh` `cp_epoch_from_ts`. Its BSD arm stripped the trailing `Z` from the input while the `-j -f` format kept the literal `Z`; BSD `date` matches that format literally, so every heartbeat parsed as undatable and `cp_probe_lease_expired` (undatable = expired) took a live lease over. The `Z` shape now keeps `Z` in both input and format; only the `+hh:mm` offset shape strips the offset. `skills/control-plane/test.sh` section 10 gains a BSD-`date` shim arm (`-d` is a DST spec, `-j -f` matches literally, `-r` takes an epoch) that runs the live-lease fixture under it and asserts the WARN row, zero ` start ` rows, the `retry after lease expiry` row, and hygiene `SKIP`. Suite: 141 checks → 144. |
| 2026-11-20 | M5's daemon-verb follow-up line is re-pointed (CDT-660, SPEC-044 AC14): the verb stays a phase-4 concern (CDT-631); the chiefd-side takeover scan of SPEC-044 is landed, so the single-node reboot contract needs no daemon verb (SPEC-044 OQ7) and linger stays M10's operator step. No other MUST, AC, or Test text changed. |
| 2026-11-19 | Spec-alignment pass (CDT-658, Step 10b): M6 names the **installed** `%h/.local/bin/node-agent` for the binary row (a `dist/`-only node is WARN), M1 states why `--status` skips the journal read on a node with no journal (the CLI creates the database on open), M12 names the post-expiry takeover (`run.Lease.Expired` semantics, exactly one `start`), Boundaries adds the `skills/lib/record-status.sh` record-and-render home and the by-path split of the two ADR 0001 crossings, AC14 drops the pre-D1 "units name `%h/.local/bin/node-agent`" wording, Test items (13)–(15) bind the three fixes, and all 14 ACs carry the M14(g) `Verify: bash <path>` grammar. |
| 2026-11-19 | T9 re-run follow-ups (CDT-658): M5 records that the legacy-unit purge runs in install as well as uninstall, so the `systemctl --user reset-failed` that clears the purged unit's `failed` state follows both purge paths (M9's uninstall reset is unchanged). SPEC-043 is registered in `specs/TDD.md` and `skills/control-plane` in `specs/OWNERS` (`tools/spec-lint.sh`). All 14 ACs PASS on the real-node cycle. |
| 2026-11-19 | T8 replan (CDT-658, TL-ruled, DRI-approved): the T7 real-node cycle failed AC1/AC13, so (D1) M5/M3/M6/M9/M12 drop the node-agent unit — phase 1 ships the `dev-team-chiefd.service` unit only and the node agent stays a by-path CLI (the daemon verb that would make a unit correct is a control-plane follow-up ticket); (D2) M11 + M2(g) — the probe start carries the resolved selection as the per-invocation `$DEVTEAM_RUNNER` child override, never a `node.json` write; (P3) M9 — uninstall runs `systemctl --user reset-failed`. AC1/AC2/AC3 follow the one-unit wording; AC13 is unchanged. |
| 2026-11-19 | T0 spike (CDT-658): both Open Questions closed with probe evidence — re-`start` on a completed run refuses (exit 1, zero journal writes), the full journal-state branch for M12, the `stop`-verb dead end M11 records for a ruling, the probe exit-code blind spot, the `loginctl` linger output shape, and the `.wslconfig` evidence split (`[wsl2] vmIdleTimeout` is the VM timer; `[general] instanceIdleTimeout=-1` is the documented distro key). No MUST/AC text changed. |
| 2026-11-19 | Created (CDT-658). One-command build/install/enable/verify for the phase-1 control plane; `--status`, `--uninstall`; one `/doctor` row; never-sudo user-units install; the approved-digest-only build. |

## Acceptance criteria

### CDT-658

- **AC1.** Fresh install: on a supported node (native Linux with systemd, or
  WSL2 with systemd=true) inside a dev-team checkout with no prior install,
  one `/setup control-plane` run ends with every verify-table row PASS except
  linger and (on WSL2) the Windows-side rows (WARN per AC7/AC10). PASS =
  chiefd answers on 127.0.0.1:8090, the chiefd unit is active via
  `systemctl --user status`, and the installed node-agent binary answers its
  `status-node` verb with exit 0 (M6: a binary row, no node-agent unit).
  Verify: bash skills/control-plane/test.sh
- **AC2.** Idempotent re-run: second immediate run exits PASS with a
  byte-identical unit file, unchanged `is-enabled`/`is-active` state, no
  error on rebuild, no duplicate probe run in the journal.
  Verify: bash skills/control-plane/test.sh
- **AC3.** Uninstall, Linux-side only: disables/stops the chiefd unit, removes
  its unit file and both installed binaries (node agent at
  `~/.local/bin/node-agent` — an installed CLI with no unit, chiefd from its
  install location), runs `daemon-reload` and `systemctl --user reset-failed`
  so the user manager is not left `degraded`, exits 0.
  Journal untouched and verifiably present after. Prints operator steps for
  the Windows Task Scheduler task and `.wslconfig`/`wsl.conf` lines; never
  touches Windows. A subsequent install reaches PASS.
  Verify: bash skills/control-plane/test.sh
- **AC4.** No sudo; digest-pinned image only: never invokes sudo; every write
  target under `$HOME` or user-writable. Only image:
  `docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea`;
  any other reference aborts preflight before side effects.
  Verify: bash skills/control-plane/test.sh
- **AC5.** Checkout-only preflight: verifies `control-plane/go.mod` exists
  under `$MROOT`; absent → non-zero exit with a clear message, nothing
  changes. Prebuilt release binaries out of scope (phase 4 / CDT-631).
  Verify: bash skills/control-plane/test.sh
- **AC6.** Runner selection read-only: reads `node.json` / `$DEVTEAM_RUNNER`,
  reports the resolved value in the verify table; absent = native. Never
  writes `node.json` or `$DEVTEAM_RUNNER`.
  Verify: bash skills/control-plane/test.sh
- **AC7.** WSL2 auto-start rows (WARN-level): verify table has rows for (a)
  `systemd=true` in `/etc/wsl.conf`, (b) the Windows Task Scheduler
  auto-start task (`wsl.exe` at logon), (c) the `.wslconfig` idle-shutdown
  setting — the distro key `instanceIdleTimeout` (`-1` disables
  auto-shutdown) primary, `vmIdleTimeout` named second (Windows 11 only).
  (b), (c) cannot be verified from inside WSL: each reports WARN with the
  exact operator step until the operator confirms. Post-reboot proof is OUT
  OF SCOPE here — it moves to CDT-659 (Phase 1 — Validation).
  Verify: bash skills/control-plane/test.sh
- **AC8.** Unsupported platform: on macOS, Linux without usable
  `systemctl --user`, WSL2 without systemd=true, or a non-checkout install,
  print one clear unsupported/failed-preflight message, exit non-zero with a
  distinct exit code, zero side effects.
  Verify: bash skills/control-plane/test.sh
- **AC9.** Preflight fail-closed: every preflight failure (docker
  absent/unreachable, image not digest-pinned or unpullable, `$MROOT`
  unresolvable, runner selection invalid) exits non-zero before
  build/install, names the failing check and its fix, leaves no partial
  state.
  Verify: bash skills/control-plane/test.sh
- **AC10.** Linger never self-serves: when `loginctl show-user "$USER" -p
  Linger` reports no, print the exact `sudo loginctl enable-linger "$USER"`
  line, wait for operator confirmation (documented continue/skip behavior),
  never execute sudo, proceed to PASS on re-check once linger is on.
  Verify: bash skills/control-plane/test.sh
- **AC11.** `journalctl` collision resolved by path, not rename: the service
  CLI keeps its name, is never placed on PATH; docs and the verify probe
  always invoke it by its `control-plane/dist/` path.
  Verify: bash skills/control-plane/test.sh
- **AC12.** Exit-code contract: exit 0 when the verify table has only
  PASS/WARN rows; non-zero on any FAIL. Reuse `/doctor`'s exit-code scheme;
  one distinct non-zero code reserved for unsupported platform.
  Verify: bash skills/control-plane/test.sh
- **AC13.** Probe hygiene + loopback invariant: verify probe starts one run
  via the node agent and verifies no runner process or container remains
  afterward (the T0 ruling drops the `stop` verb from the probe flow — a
  stop of the fixed id poisons it, Q1b); probe start journaled. After
  install chiefd binds loopback only (127.0.0.1:8090); never widen the bind.
  Verify: bash skills/control-plane/test.sh
- **AC14.** Docs and evidence stay true: `commands/setup.md` documents the
  mode (synopsis, flags, unsupported-platform behavior), the `docs/commands/`
  hub lists the sub, README commands table lists it, docs-drift passes.
  `docs/internal/control-plane/native-runner.md` carries the install-path and
  unit decision record (the D1 deferral and the D2 runner override), and the
  phase-1 dogfood run and reboot acceptance test cite `/setup control-plane`
  as their install step (the reboot test itself executes under CDT-659).
  Verify: bash skills/docs-drift/test.sh

### CDT-666

- **AC1.** The chiefd unit carries the service env at install: `WorkingDirectory`
  and `Environment="DEVTEAM_MROOT=…"` equal the checkout root the install
  resolved, and the PATH line prepends the probed user CLI dirs
  (`$HOME/.grok/bin`, the binary dir) ahead of the systemd defaults — a
  fresh install serves the project's journal and the chief-routed spawn
  resolves the host CLI without an operator drop-in; a root that is not a
  directory refuses (rc 63) before stamping.
  Verify: bash skills/control-plane/test-units.sh
- **AC2.** The verify table proves the service env: the served-journal row
  answers from `$MROOT/.claude/runs/run.db` (the probe run the install
  journaled names the project's store), and the service-env row parses
  `systemctl --user show -p Environment` and resolves the host CLI by
  `command -v` inside the stamped PATH. Both SKIP under the M10 skip
  answer.
  Verify: bash skills/control-plane/test.sh
- **AC3.** A re-run on a hand-wired node is idempotent and never clobbers
  the operator's drop-in: the unit file rewrites byte-identical and
  `.service.d/override.conf` survives untouched.
  Verify: bash skills/control-plane/test-units.sh
- **AC4.** [process] SPEC-043 M5 and the runner contract name the stamped
  env and the drop-in rule. The gate for this change is the
  control-plane shell suites plus `tools/spec-lint.sh`.

### CDT-670

- **AC1.** Replace-then-restart: when an install writes a chiefd binary whose
  content differs from the installed one (the M12 tmp+rename write of
  `cp_publish`), or renders a chiefd unit file whose content differs, setup
  restarts the unit after the daemon-reload — `systemctl --user restart
  dev-team-chiefd.service`. The restart is the CDT-660 shutdown path: the
  SIGTERM journals no run event (SPEC-044 M8), a live lease is left to
  expire, and the new process's startup takeover scan re-supervises the
  in-flight run — no `halted:operator_halt` row is written.
  Verify: bash skills/control-plane/test-units.sh
- **AC2.** Idempotent re-run: an immediate re-run with no binary or unit
  change performs no restart (the unit's main PID is unchanged across the
  re-run), keeps the byte-identical unit file, and still exits PASS.
  Verify: bash skills/control-plane/test-units.sh
- **AC3.** Currency verify row: the verify table gains a row that compares
  the running chiefd's process start time (`systemctl --user show -p
  ExecMainStartTimestamp --value`) against the installed binary's mtime.
  Active-and-current is PASS; active-but-older-than-the-binary is FAIL that
  names the exact restart command; an unreadable timestamp is WARN, never a
  spurious FAIL, and the row participates in the AC12 exit-code contract.
  Verify: bash skills/control-plane/test.sh
- **AC4.** Docs stay true: `skills/control-plane/SKILL.md` documents the
  restart-on-replace rule and the currency row, and `commands/setup.md`
  names the new verify row; docs-drift passes.
  Verify: bash skills/docs-drift/test.sh
- **AC5.** [process] The change is proven by the control-plane shell suites
  (`skills/control-plane/test.sh`, `skills/control-plane/test-units.sh`)
  plus `tools/spec-lint.sh`.
