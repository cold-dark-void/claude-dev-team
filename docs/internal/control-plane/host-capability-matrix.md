# Host capability matrix

Carries AC-1..AC-5. Each probe task owns its host section below and appends rows only there. mini-swe rows are documentation-only (T-06).

## AC-1 — Host × Runner capability matrix

Every cell uses the index vocabulary (`supported` / `unsupported` / `unverified-after-attempt`) with the AC-2 evidence fields. Capabilities: (a) session resume after process death, (b) headless mode with streaming input and output, (c) Steer delivery at the next step boundary, (d) hooks or another lifecycle-event emission path, (e) workflow compatibility per AC-5, (f) memory (optional column), (g) Intercom (optional column). Memory and Intercom are never scored as required.

### Claude Code 2.1.322

<!-- T-03 owns these rows. Native probed 2026-11-15; container half probed 2026-11-15 under G-02 row 1 approval (debian:trixie-slim, digest-pinned). -->

Version drift flag: the plan locked Claude Code 2.1.322; the installed CLI is **`claude 2.1.325 (Claude Code)`** (`claude --version`, probed 2026-11-15). All cells below record the actual version 2.1.325.

| Capability | Native | Container | Notes |
|---|---|---|---|
| (a) session resume after process death | **supported** — claude 2.1.325, probe 2026-11-15 | **supported** — claude 2.1.325, container probe 2026-11-15 (G-02 row 1 approved) | Native: flag `-r/--resume <session-id>`, probe P-CC-A. Container: same flag, resumed across container death — P-CON-A below. |
| (b) headless mode with streaming input and output | **supported** — claude 2.1.325, probe 2026-11-15 | **supported** — claude 2.1.325, container probe 2026-11-15 (G-02 row 1 approved) | Native: `claude -p --verbose --input-format stream-json --output-format stream-json` (stream-json output in `--print` mode requires `--verbose`; first attempt errored: `Error: When using --print, --output-format=stream-json requires --verbose`). Probe P-CC-B. Container: same flags over a container-internal fifo — P-CON-STEER below. |
| (c) Steer delivery at the next step boundary | **supported** — claude 2.1.325, probe 2026-11-15 | **supported** — claude 2.1.325, container probe 2026-11-15 (G-02 row 1 approved) | Native: reproduced probe P-CC-C (AC-3). Container: reproduced probe P-CON-STEER — mid-turn injection delivered at the next step boundary; the transcript carries the same `absorbed_mid_turn` queue record as native. |
| (d) hooks / lifecycle-event emission path | **supported** — claude 2.1.325, probe 2026-11-15 | **supported** — claude 2.1.325, container probe 2026-11-15 (G-02 row 1 approved) | Flag `--include-hook-events` (with `--output-format=stream-json`) emits lifecycle events into the output stream. Native probe P-CC-D; container probe P-CON-1 (same event shapes inside the container). |
| (e) workflow compatibility per AC-5 | **supported** — see AC-5 checklist scores below (all four items pass, claude 2.1.325, probe 2026-11-15) | **supported** — all four items pass in the container too; see AC-5 § Checklist scores (container column) | Native: one headless run exercised all four items. Container: P-CON-C1..C3 + P-CON-B below. |
| (f) memory (optional column) | **supported** — claude 2.1.325, probe 2026-11-15 | **unverified-after-attempt** — claude 2.1.325, container probe 2026-11-15 | Native: `sqlite3 $MROOT/.claude/memory/memory.db "SELECT count(*) FROM memories WHERE agent='ic4'"` → `399`. Container: the per-project DB file is reachable (mounted with the repo at the same absolute path), but the SQL probe failed inside the approved throwaway image — see P-CON-M. |
| (g) Intercom (optional column) | **unverified-after-attempt** — claude 2.1.325, probe 2026-11-15 | **unverified-after-attempt** — claude 2.1.325, container probe 2026-11-15 | Native: skill surface exists and is configured; live end-to-end delivery not run (real Telegram side effect outside a docs probe). Container: `bash skills/intercom/intercom.sh help` inside the approved throwaway image exits 0 and prints usage (P-CON-G); `jq` is not in the gate-approved package set, so the spool verbs were not exercised in-container; live delivery out of probe scope, same as native. |

### Probe transcripts (Claude Code, native)

All probes on host CLI `claude 2.1.325 (Claude Code)`, date 2026-11-15.

**P-CC-A — session resume after process death (capability a).** Session started headless (P-CC-B flags), session id taken from the stream-json output, then the process was killed:

```
$ pgrep -f 'claude -p --verbose' | head -1
45688
$ kill -9 45688
$ claude -p --resume 462ad42c-1750-4324-9bfa-15e5fcc3dc0f "What number did I ask you to remember earlier in this session? Reply with just the number."
47
```

The resumed session answered `47` — the fact planted in the killed session. Mechanism the Host adapter would call: `claude -p --resume <session-id>`; session id read from the `system/init` stream-json event.

**P-CC-B — headless streaming (capability b).**

```
$ claude -p --input-format stream-json --output-format stream-json --include-hook-events ...
Error: When using --print, --output-format=stream-json requires --verbose
```

Working invocation (`<message>` is a stream-json user message, `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"…"}]}}`):

```
$ claude -p --verbose --input-format stream-json --output-format stream-json \
    --include-hook-events --replay-user-messages \
    --permission-mode bypassPermissions --allowedTools "Bash(sleep:*)" < in.fifo > out.jsonl
```

Observed: stdout received 24 realtime stream-json events over the session (init, hook events, assistant text deltas via tool results, result with usage/cost). Stdin accepted a user message mid-session (turn 2), proving streaming input, not just one-shot prompts.

**P-CC-C — Steer (capability c, AC-3).** Inside the running P-CC-B session: turn-2 message instructed `sleep 25 && echo SLEEP2-DONE`; the steer message was written to the session's stream-json stdin 3 s later, while the Bash tool call was still executing:

```
$ printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Steer: after the sleep finishes, include the exact token STEER-RECEIVED-47 in your final reply."}]}}' > in.fifo
STEER-SENT after 3s
```

Final assistant text of that turn (verbatim from out.jsonl):

```
"text":"`SLEEP2-DONE` printed (exit 0, run in the background) — STEER-RECEIVED-47"
```

The injected message was consumed at the next step boundary (after the running tool step finished), not lost and not a separate fire-and-forget turn. AC-3 standard met.

**P-CC-D — hooks / lifecycle events (capability d).** Same session, `--include-hook-events` on. Event counts across one session (hook_started + hook_response pairs):

```
$ grep -o '"hook_event":"[A-Za-z:]*"' out.jsonl | sort | uniq -c
      8 "hook_event":"PreToolUse"
      4 "hook_event":"SessionStart"
     12 "hook_event":"Stop"
      8 "hook_event":"UserPromptSubmit"
```

Sample verbatim line (SessionStart, startup):

```
{"type":"system","subtype":"hook_started","hook_id":"82dba6f0-b428-4948-898c-9fc7a854abcf","hook_name":"SessionStart:startup","hook_event":"SessionStart","uuid":"4445ac70-37f4-49f3-ad2f-61f8ecc69230","session_id":"462ad42c-1750-4324-9bfa-15e5fcc3dc0f"}
```

The emission path is the stream-json output stream itself (no separate bus); hook lifecycle events appear as `system` records with `hook_started` / `hook_response` subtypes.

#### Container probe transcripts (Claude Code)

All probes inside a throwaway `docker run --rm` container from the G-02-approved image (row 1: `debian:trixie-slim`, digest-pinned `sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2`), host CLI `claude 2.1.325` mounted read-only from `/home/malcolm/.local/share/claude/versions/2.1.325`, auth file mounted read-only from `/home/malcolm/.claude/.credentials.json` (paths only — no secret values printed), the host repo mounted at its host path so the worktree sits at the same absolute path, probe date 2026-11-15. Toolchain inside the image: `apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y git curl ca-certificates` (the gate-record pre-approved set), then a drop to uid 1000 (`groupadd -g 1000 probe; useradd -u 1000 -g 1000 probe; setpriv --reuid=1000 --regid=1000 --init-groups`).

**P-CON-1 — hooks + streaming inside the container (capabilities b, d).** Same invocation shape as P-CC-B, run inside the container against a container-internal fifo. Verbatim init line from the container session's stream-json stdout:

```
{"type":"system","subtype":"init","cwd":"/home/malcolm/vibes/claude-dev-team/.worktrees/CDT-627","session_id":"c26ca24d-c54d-483d-be4f-3aaf03495fe1","tools":["Task","Bash",...]}
```

Hook-event counts across that in-container session (`--include-hook-events`, same grep as P-CC-D):

```
      6 "hook_event":"PreToolUse"
      4 "hook_event":"SessionStart"
      4 "hook_event":"Stop"
      2 "hook_event":"UserPromptSubmit"
```

Same event shapes as native; the emission path (stream-json output stream) is unchanged inside the container.

**P-CON-STEER — Steer inside the container (capability c, AC-3).** Reproduced probe, P-CC-C shape: a two-turn stream-json session over a container-internal fifo; turn 2 started a `sleep 20 && echo S2-DONE` Bash tool call; the steer message was written to the session's stdin 3 s after turn 2 (while the tool call was still pending), and the session was kept alive by holding the fifo's write end open (see the EOF note below). Verbatim final assistant text:

```
TURN2-DONE STEER-CON8-44
```

`STEER-CON8-44` was the token carried only by the injected message — delivery at the next step boundary, turn not interrupted. The session transcript records the same queue mechanic as native P-CC-C:

```
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-15T08:34:33.611Z",...}   # turn 2
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-15T08:34:36.612Z",...}   # steer
"reason":"absorbed_mid_turn","commandUuid":"b681845e-...","deliveryId":"15659f44-..."          # steer absorbed into the running turn
```

Probe failure record (kept per AC-2 — three attempts failed before the fourth reproduced): in the first three attempts each stdin write was `printf … > fifo`, which opens-writes-closes the fifo; after the first chunk of input was consumed the CLI's next read hit fifo EOF, no later message was ever read, and the messages never reached the model (token counts 0). The working probe holds the fifo's write end open for the session's lifetime (`exec 3>/tmp/in.fifo … exec 3>&-`). Host-adapter note: a stream-json stdin pipe to a containerized `claude -p` must be held open (no EOF) until the session should end, or only the messages present at startup are seen.

**P-CON-A — session resume across container death (capability a).** The P-CON-STEER session (id `951da70d-f18e-47ee-a7f4-7de94bff2b33`, transcript under `~/.claude/projects/-home-malcolm-vibes-claude-dev-team--worktrees-CDT-627/`) ended when its container exited. A new container (fresh filesystem, same read-only mounts) resumed it:

```
$ claude -p --resume 951da70d-f18e-47ee-a7f4-7de94bff2b33 "What exact token did I ask you to include in your final reply in the last turn of this session? Reply with just the token." --permission-mode bypassPermissions
STEER-CON8-44
RESUME_EXIT:0
```

Mechanism: the same `claude -p --resume <session-id>` flag as native (AC-4); the transcript lives on the host volume (`~/.claude/projects/`), so the container Runner needs `~/.claude` mounted (read-write for transcripts) and resume works across container death with no copy step.

**P-CON-B — worktree at the same absolute path (AC-5 item 4, AC-6 fact 3).** Headless container session with the host repo bind-mounted at its host path:

```
$ claude -p "Run exactly these two commands with the Bash tool and report their exact output on separate lines and nothing else: pwd; git branch --show-current"
/home/malcolm/vibes/claude-dev-team/.worktrees/CDT-627
feat/CDT-627
WT_EXIT:0
```

The session sees the worktree at the identical absolute path and the correct branch — SPEC-016 absolute-path semantics hold under a host-path bind mount.

**P-CON-C1 — Surface headless (AC-5 item 1).** The dev-team `/status worktree` surface invoked through the Skill tool inside a container headless session (the bare `"/status worktree"` prompt resolves to nothing in `-p` mode — native control run confirmed the same refusal):

```
$ claude -p "Invoke the Skill tool with skill 'dev-team:status' and args 'worktree'. Then report the worktree summary line of its output verbatim."
The worktree status output is one line:

CDT-627 | feat/CDT-627 | FRESH | 4h47m | 5edb490 fix: v1.28.20 — backlog journal-skip: the BSD parser accepts the mandated minute-precision ts (CDT-636)

The plugin directory resolved to this worktree's own copy (`/home/malcolm/vibes/claude-dev-team/.worktrees/CDT-627`), not the installed cache.
SURF_EXIT:0
```

**P-CON-C2 — spawn the roles (AC-5 item 2).** Container headless session spawned the plugin's `dev-team:finder` agent through the Task tool; reply verbatim `READY` (`ROLE_EXIT:0`).

**P-CON-C3 — decision-cards (AC-5 item 3).** Container headless session wrote `.claude/autopilot/decision-cards/probe-cdt627-con.md` (one line, `CDT-627 container probe card`); content verified on the host volume after the container exited; probe artifact removed afterward.

**P-CON-M — memory reachability (capability f, container).** The session found the mounted DB and ran the query; the approved image lacks the shared library the host `sqlite3` binary links:

```
/home/u/bin/sqlite3: error while loading shared libraries: libreadline.so.8: cannot open shared object file: No such file or directory
MEM_EXIT:0
```

The host binary was mounted read-only (`/usr/sbin/sqlite3` → `/home/u/bin/sqlite3`); `libreadline8` is not in the gate-approved package set, so it was not installed. The DB file itself is reachable from the container (mounted with the repo); the SQL path is what failed. Verdict: `unverified-after-attempt` for the container memory cell.

**P-CON-G — Intercom attempt (capability g, container).** Inside the approved image: `bash skills/intercom/intercom.sh help` → the usage block prints, `INTERCOM_EXIT:0`; `command -v jq` → `jq-missing` (not in the approved package set). Live delivery deliberately not attempted (same scope reason as native).

### Grok 1.0.77

<!-- T-04 owns these rows. Disjoint from Claude Code. Native and container halves probed 2026-11-15 (G-02 approved: debian:trixie-slim, row 1 only). -->

| Capability | Native | Container | Notes |
|---|---|---|---|
| (a) Session resume after process death | **supported** — grok 1.0.77, probed 2026-11-15 | **supported** — grok 1.0.77 in container, probed 2026-11-15 | `--resume <SESSION_ID_OR_TITLE>`; session id from the headless JSON output (`sessionId` field). Container: works with `~/.grok/sessions/` mounted **read-write**; a read-only sessions mount fails (`Couldn't create session: session load was superseded`, exit 1). Probe P-GK-CTR-2 below. |
| (b) Headless mode with streaming stdin/stdout | **supported** — grok 1.0.77, probed 2026-11-15 | **supported** — grok 1.0.77 in container, probed 2026-11-15 | Streaming stdout via `--output-format streaming-json`; conversational streaming stdin/stdout via `grok agent stdio` (ACP). Single-turn stdin is prompt-supply only. Both reproduced in-container (P-GK-CTR-1, P-GK-CTR-3c). |
| (c) Steer delivery at the next step boundary | **supported** — grok 1.0.77, probed 2026-11-15 | **supported** — reproduced in-container, grok 1.0.77, probe 2026-11-15 | Mid-turn `session/prompt` injected during a running tool step; delivered at the next boundary. Container reproduction: P-GK-CTR-3c below and the Steer probe record. Adapter note: declare `terminal: false` in the ACP client capabilities so grok executes tools through its own shell (`grokShell`); with `terminal: true` the agent sends a `terminal/create` request to the client and stalls unless the client implements the `terminal/*` methods. |
| (d) Hooks / lifecycle-event emission path | **supported** — grok 1.0.77, probed 2026-11-15 | **supported** — grok 1.0.77 in container, probed 2026-11-15 | `~/.grok/hooks/*.json` + project `.grok/hooks/*.json`; 15 hook events (doc + live config + ACP capability advertisement). Container: the ro-mounted `PreToolUse` hook config + hook script at the same absolute host path fired and denied a `read_file` of a `.png` (P-GK-CTR-4). |
| (e) Workflow compatibility (AC-5) | **supported** — all four items pass, see AC-5 checklist scores below (grok 1.0.77, probed 2026-11-15) | **supported** — all four container-testable items pass, see AC-5 container checklist scores (grok 1.0.77, probed 2026-11-15) | Scored per item in the AC-5 checklist section below. |
| (f) Memory (optional) | **supported** — grok 1.0.77, probed 2026-11-15 | **unsupported** — automatic injection absent in-container; three attempts recorded, grok 1.0.77, probe 2026-11-15 | `~/.grok/memory/` + `~/.grok/memory-v2/` mounted read-only at the host paths; the workspace memory index was not injected into the session context even with the workspace resolving correctly (git toplevel `feat/CDT-627` verified in-container, P-GK-CTR-8c). Host-adapter fallback: load memory explicitly through the memory protocol against the mounted dirs. |
| (g) Intercom (optional) | **supported** — grok 1.0.77, probed 2026-11-15 | **supported** — grok 1.0.77 in container, probe 2026-11-15 | Intercom is a file-spool CLI (bash+jq+curl); the bundled `intercom.sh help` verb ran inside the container from the ro-mounted marketplace cache (P-GK-CTR-8). Live delivery not probed — same scope limit as the native cell. |

**Native probe environment:** `grok --version` → `grok 1.0.77 (50ca579fa996) [stable]`; binary `/home/malcolm/.grok/bin/grok`. Probe date: 2026-11-15. Version matches the plan lock (Grok 1.0.77) — no drift.

**Container probe environment:** image `debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2` (G-02 approved, row 1); `docker run --rm` throwaway containers, no build, no compose. The host binary (statically linked, `file` → `grok-1.0.77-linux-x86_64`) is bind-mounted read-only at `/usr/local/bin/grok` and reports the same version in-container: `grok --version` → `grok 1.0.77 (50ca579fa996)` — no drift. Mounts per probe: `~/.grok/auth.json:ro`, `~/.grok/auth.sh:ro`, `~/.grok/config.toml:ro` (subscription auth and model routing), plus probe-specific mounts (sessions dir, hooks, memory dirs, marketplace cache, worktree repo). In-container `apt-get install git curl ca-certificates` per the G-02 gate record. Probe date: 2026-11-15.

#### Native evidence — (a) session resume

Probe 1 (create, process exits after):

```
$ grok -p "Remember the number 42 for later. Reply with exactly: OK" --output-format json
{"sessionId":"01a1dddd-7681-7242-961b-303ae89a105a","stopReason":"end_turn","text":"OK","isError":null}
```

Probe 2 (new process, resume by id):

```
$ grok -p "What number did I ask you to remember? Reply with just the number." --resume 01a1dddd-7681-7242-961b-303ae89a105a --output-format json
{"sessionId":"01a1dddd-7681-7242-961b-303ae89a105a","stopReason":"end_turn","text":"42"}
```

Session-id source (AC-4): the `sessionId` field of the headless `--output-format json` result (also in the `streaming-json` `end` event). Sessions persist per working directory under `~/.grok/sessions/`. `-c/--continue` resumes the newest session in the cwd; `--fork-session` resumes into a new session id. Vendor doc (bundled with the CLI): `~/.grok/docs/user-guide/14-headless-mode.md` § Session Management in Headless Mode, `17-sessions.md`.

#### Native evidence — (b) headless with streaming stdin/stdout

Streaming output (`--output-format streaming-json`, verbatim, trimmed):

```
$ grok -p "Reply with exactly: STREAM-OK" --output-format streaming-json
{"type":"text","data":"STREAM-"}
{"type":"text","data":"OK"}
{"type":"end","stopReason":"end_turn","sessionId":"01a1ddde-7dba-74e1-ae20-70a6eaab7167",...}
```

Formats: `plain`, `json`, `streaming-json`, `streaming-messages-json` (`--include-partial-messages` adds raw deltas). Streaming conversational stdin/stdout is the ACP transport: `grok agent stdio` speaks JSON-RPC on stdin/stdout and streams `session/update` events (`agent_message_chunk`, `tool_call`, `tool_call_update`) — exercised live in the Steer probe below. Single-turn headless reads stdin only as a prompt/context source (`14-headless-mode.md` § Piping Input and Output); there is no mid-run stdin injection surface on that route.

#### Native evidence — (d) hooks / lifecycle events

Hook locations: global `~/.grok/hooks/*.json`, project `<project>/.grok/hooks/*.json` (trust-gated; a headless run counts the folder trusted for your own hooks — `10-hooks.md` § Hook Locations). Events (`10-hooks.md` § Hook Events): `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, `Stop`, `StopFailure`, `StopCancelled`, `Notification`, `SubagentStart`, `SubagentStop`, `PreCompact`, `PostCompact`, `SessionEnd`. `PreToolUse`, `UserPromptSubmit`, `Stop`, `SubagentStop` are blocking.

Live config on this host (`ls ~/.grok/hooks/`): `no-view-images.json` — a `PreToolUse` hook, matcher `Read|read_file`, 5 s timeout.

ACP advertisement of the hook surface (verbatim, from the initialize result of the Steer probe session):

```
"x.ai/hooks":{"blockingEvents":["pre_tool_use","stop","subagent_stop"],"decisions":["deny","block"],"stopSignals":["continue","stopReason","additionalContext"]}
```

#### Native evidence — (f) memory (optional)

Vendor doc (`13-memory.md`): memory saves Markdown notes per scope (global and workspace; worktrees share the workspace scope) and injects a bounded index at session start. CLI: `grok memory clear` (`grok memory --help`); disable per process with `GROK_MEMORY=0` (`14-headless-mode.md` § Additional Headless Flags). Live on this host: `~/.grok/memory/` and `~/.grok/memory-v2/` are populated, and the workspace memory manifest is injected into session context at start.

#### Native evidence — (g) Intercom (optional)

Intercom is the file-spool CLI (SPEC-038; needs bash+jq+curl). Probe — the headless session ran the bundled script through its shell tool (`grok -p "Run exactly this shell command ... bash skills/intercom/intercom.sh help" --always-approve --output-format json`, stopReason `end_turn`, verbatim stdout):

```
usage: intercom ask [--sid S] TEXT
       intercom send [--sid S] [--summary T] [--no-summary] [--file P] TEXT
       intercom read [--sid S] [--ack]
       intercom away [on|off|status]
       intercom help
...
```

The execution path (host shell tool → plugin-bundled script) is the same one the Intercom verbs need; no network side of the spool was exercised in this probe.

#### Container probe transcripts (Grok)

All probes in throwaway `docker run --rm` containers on the approved image `debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2` (G-02 row 1), host CLI binary bind-mounted read-only, date 2026-11-15, version in-container `grok 1.0.77 (50ca579fa996)`.

**P-GK-CTR-1 — headless one-shot + streaming-json (capabilities b, AC-6 fact 1).** Mounts: `auth.json:ro`, `auth.sh:ro`, `config.toml:ro`. Inside the container:

```
$ /usr/local/bin/grok -p "Reply with exactly: CTR-OK" --output-format json
{"text":"CTR-OK","stopReason":"end_turn","sessionId":"01a1de1d-bd76-7712-9628-d9aebeda8dc1",...
 "modelUsage":{"grok-4.7-build":{...,"modelCalls":1}}}
$ /usr/local/bin/grok -p "Reply with exactly: STREAM-CTR-OK" --output-format streaming-json
{"type":"text","data":"STREAM"}
{"type":"text","data":"-"}
{"type":"text","data":"CTR"}
{"type":"text","data":"-"}
{"type":"text","data":"OK"}
{"type":"end","stopReason":"end_turn","sessionId":"01a1de1d-c51f-7401-92e8-6e65cbbedd9f",...}
```

Both formats streamed correctly in-container against the subscription backend with the auth file mounted read-only. `apt-get install git curl ca-certificates` executed in-container per the gate record (fact 4 evidence: the toolchain list).

**P-GK-CTR-2a/2b — session resume (capability a).** Host session created in `/tmp/grok-ctr-resume` (`sessionId` `01a1de1e-6bd0-78c3-aff9-98eceeb4a2b2`, reply `OK` planting the number `73`). Container, `~/.grok/sessions` mounted **read-only**:

```
$ grok -p "What number did I ask you to remember? Reply with just the number." \
    --resume 01a1de1e-6bd0-78c3-aff9-98eceeb4a2b2 --output-format json
{"type":"error","message":"Couldn't create session: session load was superseded"}
Error: Couldn't create session: session load was superseded      # exit 1
```

Same container run with `~/.grok/sessions` mounted **read-write**:

```
$ grok -p "What number did I ask you to remember? ..." --resume 01a1de1e-6bd0-78c3-aff9-98eceeb4a2b2 --output-format json
{"text":"73","stopReason":"end_turn","sessionId":"01a1de1e-6bd0-78c3-aff9-98eceeb4a2b2",...}
```

Resume works in-container and the state crossed the process/container boundary; the sessions directory must be writable (AC-2 evidence: the ro attempt errored, the rw attempt succeeded — both verbatim above).

**P-GK-CTR-3c — Steer reproduction (capability c, AC-3).** `grok agent --always-approve stdio` over JSON-RPC, client capabilities `terminal: false`, cwd `/tmp`. Setup and injection:

```
→ initialize (id 1) → session/new (id 2)      # session 01a1de29-d355-7fe2-bdcf-1e490e6d9ec2
→ session/prompt (id 3): "Run the shell command sleep 15, then reply exactly STEP-DONE."
  (+6 s, while the sleep tool call is running)
→ session/prompt (id 4): "Additional instruction: when you finish, also reply the word STEERED-CTR."
```

Key frames (verbatim, trimmed):

```
tool_call_update: "Execute `sleep 15`" → status "in_progress" → status "completed"
  (rawOutput: {"type":"Bash","output_for_prompt":"exit: 0\n","exit_code":0,"command":"sleep 15",...})
_x.ai/queue/changed: {"entries":[{"kind":"prompt","text":"Additional instruction: ... STEERED-CTR.",
  "position":0}],"runningPromptId":"0e46f574-...","runningText":"Run the shell command sleep 15, ..."}
_x.ai/queue/changed: {"entries":[],...}                          # steer consumed at the boundary
agent_message_chunk: "STEP" + "-" + "DONE" + "\n" + "STE" + "ER" + "ED" + "-" + "CTR"
{"id":4,"result":{"stopReason":"cancelled","_meta":{...,"completionKind":"removedFromQueue"}}}
{"id":3,"result":{"stopReason":"end_turn","_meta":{...,"numTurns":2,"modelCalls":2}}}
```

Same mechanics as the native ACP steer: the mid-turn prompt was merged into the running turn (queue entry consumed after the tool step completed), the final message carried both `STEP-DONE` and `STEERED-CTR`, and the id-4 request resolved `cancelled` / `removedFromQueue`. Delivery at the next step boundary: reproduced in-container. Failed variant kept as adapter evidence (P-GK-CTR-3b, same runbook with `terminal: true`): the agent emitted a client request `{"id":0,"method":"terminal/create","params":{...}}` and the turn stalled because the client never answered the `terminal/*` methods — hence the `terminal: false` requirement in the (c) cell.

**P-GK-CTR-4 — hooks (capability d).** Mounts: `~/.grok/hooks/no-view-images.json:ro` at `/root/.grok/hooks/`, hook script ro at `/home/malcolm/.claude/hooks/no-view-images.sh` (the path the hook config invokes). Inside the container:

```
$ printf "fake-png-bytes" > /tmp/probe.png
$ grok -p "Use the read_file tool on /tmp/probe.png and report exactly what the tool returns." \
    --always-approve --output-format json
"text":"I'll read `/tmp/probe.png` and report the tool output exactly.Hook denied: HARD RULE: do not
visually inspect images without explicit user permission. Blocked: /tmp/probe.png. Grant: ... or
ALLOW_IMAGE_VIEW=1. Use boxes/metrics/hashes only."
```

The PreToolUse hook fired in-container and denied the read — hook execution works with the config and script mounted read-only at their host paths.

**P-GK-CTR-5/5b — workflow items (capability e).** Scratch git repo bind-mounted read-write at the same host path `/tmp/grok-ctr-wt`. First attempt hit git's `safe.directory` guard (host-uid repo, container-root git): `fatal: detected dubious ownership in repository at '/tmp/grok-ctr-wt'` — fixed with `git config --global --add safe.directory /tmp/grok-ctr-wt`. Then, inside the container (P-GK-CTR-5b):

```
$ git worktree add .worktrees/probe-ctr -b probe-ctr
Preparing worktree (new branch 'probe-ctr')          # SPEC-016 layout: .worktrees/<slug> in the repo root
$ cd .worktrees/probe-ctr && grok -p "Print only the absolute path of the current working directory
    and the current git branch." --always-approve --output-format json
{"text":"/tmp/grok-ctr-wt/.worktrees/probe-ctr\nprobe-ctr","stopReason":"end_turn",...}
```

Worktree created at `.worktrees/<slug>` inside the project root and grok ran inside it at the same absolute path inside the container. Decision-card item (P-GK-CTR-5, ro-mounted marketplace clone): the session ran `bash /home/malcolm/.claude/plugins/marketplaces/cold-dark-void/skills/autopilot/append-card.sh orchestrate CDT627CTR ship-choice proceed auto null 80 null run-ctr 1 5 grok container-probe-card`; the card on disk (verbatim, last line of `.claude/autopilot/CDT627CTR.jsonl`):

```
{"schema_version":1,"type":"autopilot_decision","ts":"2026-11-15T07:51:14Z","run_id":"run-ctr","workflow":"orchestrate","ticket_id":"CDT627CTR","gate":"ship-choice","decision":"proceed","decided_by":"auto","bump":null,"confidence":80,"blocking_condition":null,"council_tier":null,"grading_reason":null,"max_loc":null,"rationale":"container-probe-card","budget":{"iteration":1,"iteration_cap":25,"wall_clock_s":5,"wall_clock_cap_s":2700,"tier":null,"source":null,"signals":null},"actor":"grok","advisor":null}
```

Inline-roles item (P-GK-CTR-5): one headless reply carried `PM:` and `TL:` lines about the scratch repo. Scratch repo removed after the probe.

**P-GK-CTR-6 — Surface headless (AC-5 item 1).** `~/.grok/marketplace-cache:ro` mounted; from cwd `/tmp`:

```
$ grok -p "/dev-team-edge:status worktree" --always-approve --output-format json
"text":"**Worktree status:** no plugin-managed worktrees.\n\n`/status worktree` finished read-only
(exit 0) and printed no rows. ... The dev-team plugin resolved as version 1.28.20 from the Grok
marketplace cache. Nothing was created, locked, or removed."
```

The session resolved the plugin from the mounted marketplace cache and executed the read-only Surface end-to-end in-container.

**P-GK-CTR-8/8b/8c — memory injection (capability f).** Three attempts, `~/.grok/memory` + `~/.grok/memory-v2` mounted ro at the host paths: at cwd `/` (8) → NO; at the CDT-627 worktree path with only the worktree mounted (8b) → the workspace itself failed (`fatal: not a git repository: /home/malcolm/vibes/claude-dev-team/.git/worktrees/CDT-627` — a linked worktree needs the main repo's `.git`, which was not mounted) and the answer was NO; with the main repo and the worktree both mounted at their host paths and the workspace verified in-container (`git rev-parse --show-toplevel` → the CDT-627 path, branch `feat/CDT-627`) the answer was still NO:

```
$ grok -p "Does your session context include a workspace or global memory index ...?"
{"text":"NO\nNo memory-index topic title is present in this session context.",...
 "sessionId":"01a1de38-b394-7722-82c6-8382c68544c9"}
```

Verdict: the automatic workspace-memory-index injection did not occur in-container under the probe mounts (native: injected). Recorded as `unsupported` for the automatic path; a host adapter can load memory explicitly from the mounted `~/.grok/memory*/` directories.

**P-GK-CTR-7 — credential-restart survival (AC-9).** Every probe above ran in its own `docker run --rm` container instance (nine independent containers across P-1..P-8c); each authenticated from the same read-only-mounted `~/.grok/auth.json` — the mounted-volume credential survives container restart by construction of the mount, and the repeat is observed in every probe's output.

### omp 18.7.0

<!-- T-05 owns these rows. Disjoint from Claude Code and Grok. Check `docs/runbooks/omp.md` and `docs/internal/omp-host.md` for drift; do not edit them. -->

Host CLI: `omp --version` → `omp/18.7.0` at `/usr/sbin/omp`. Probe date: 2026-11-15. Matches the plan lock (omp 18.7.0) — no version drift.

Version drift flag (2026-11-17, CDT-648 B7): the plan locks omp 18.7.0; the node's installed build is now **`omp v18.22.0`** (`omp --version`; binary `/usr/sbin/omp`, replaced 2026-11-17 01:30 — `~/.omp/natives/` carries only `18.22.0`, the 18.7.0 binary is gone). The 18.7.0-probed rows below stand as dated evidence (2026-11-15); the CDT-648 B7 env-var-name probe ran on the installed 18.22.0 build (`credentials.md` § "Gap 2 — resolved: the omp provider env-var names (B7)").

Drift flag vs `docs/runbooks/omp.md` (CDT-550, 2026-10-13): the runbook's blocker **B1** ("omp tool-calling dead in print mode — zero tool_call events") no longer holds for the current model set. With `spark-tf/glm5.3-flash-320b-a18b-8x512k-exl3-kv8-dflash2-tp2` over the `openai-completions` shim, real tool calls executed in print and RPC mode (bash tool call, `task` subagent spawn — probes below). B1 was backend-specific (local ollama + the `openai-responses` shim), not an omp host limit. Second drift: a bare `omp -p` with no `--model` resolved to `ollama/laya:latest`, which fails with `400 "laya:latest" does not support chat` — pin `--model` explicitly for probes and adapter runs.

| Capability | Native | Container | Notes |
|---|---|---|---|
| (a) session resume after process death | **supported** — see AC-4 | **supported** — omp 18.7.0, probed 2026-11-15 (P-OMP-C-A) | omp 18.7.0, probed 2026-11-15. Container: same `-r <id>` flag; session-id source is the `{"type":"session","id":…}` frame and the transcript filename in the mounted `~/.omp/agent/sessions/<cwd-slug>/`. Resumed from a read-only mounted volume and from a session written by a previous container (restart survival). |
| (b) headless mode with streaming input and output | **supported** | **supported** — omp 18.7.0, probed 2026-11-15 (P-OMP-C-B) | Container: `-p --mode json` streamed `text_delta`; `--mode rpc` ran bidirectional JSONL stdin/stdout (steer probe). |
| (c) Steer delivery at the next step boundary | **supported** — reproduced probe, see AC-3 | **supported** — reproduced probe, omp 18.7.0, probed 2026-11-15 (P-OMP-C-C) | Container RPC steer reproduced — record in AC-3 § "omp 18.7.0 — container Steer probe record". |
| (d) hooks or lifecycle-event emission path | **supported** | **supported** — omp 18.7.0, probed 2026-11-15 (P-OMP-C-D) | Container: the RPC stream emitted `agent_start`/`turn_start`/`message_start`/`message_end`/`tool_execution_start`/`tool_execution_end`/`turn_end`/`queue_update`/`agent_end`/`prompt_result`/`session_settled`. `--hook=<file>` is in the container `omp --help`. Claude-style project `hooks/hooks.json` still does not fire (runbook CDT-550 row 1, unchanged). |
| (e) workflow compatibility per AC-5 | **supported** — all four items pass, see AC-5 checklist scores below | **supported** — omp 18.7.0, probed 2026-11-15 — 3 pass + 1 partial in the approved image, see AC-5 container scores (P-OMP-C-E) | Container items 1, 2, 4 pass. Item 3 (decision-cards) is partial: the approved image ships no `jq`, so `append-card.sh` hard-fails (exit 64) — a runner-image toolchain need, not a host limit. |
| (f) memory (optional) | **supported** | **supported** — omp 18.7.0, probed 2026-11-15 (P-OMP-C-F) | Container: the mounted volume carries `memory.backend: local` and the per-project stores at `~/.omp/agent/memories/<cwd-slug>/` (observed `--home-malcolm-.omp--`, `--home-malcolm-vibes-describer--`). Writes need the writable agent-dir mount proven in `container-runner.md` Fact 2. |
| (g) Intercom (optional) | **unverified-after-attempt** | **unverified-after-attempt** — omp 18.7.0, probed 2026-11-15 (P-OMP-C-G) | Container: the skill is discovered (`omp -p` skill-name probe returned `intercom`). Live Telegram delivery not probed — `probe.sh` hits the live Bot API by design (SPEC-038), same scope limit as the native cell. |

### omp 18.7.0 — native probe evidence

All probes run in a throwaway dir `/tmp/omp-probe-627` with `--model 'spark-tf/glm5.3-flash-320b-a18b-8x512k-exl3-kv8-dflash2-tp2'`.

**(a) Session resume — supported.** Probe command:

```
omp -p --mode json --max-time 120 -r '01a1ddda-7a27' 'What single word did I ask you to reply with earlier in this session? Answer with the word only.'
```

Output (trimmed): `{"type":"session",...,"id":"01a1ddda-7a27-760e-bd6c-a123b85f0b5e",...}` then the assistant message ended with `"text":"PONG"` — the resumed session recalled the earlier turn. `-c/--continue` continues the previous session; `-r` takes an id prefix, a session path, or a picker.

**(b) Headless + streaming — supported.** `-p/--print` runs non-interactive; `--mode json` streams stdout events. Probe command:

```
omp -p --mode json --max-time 120 'Reply with exactly PONG and nothing else. Do not use tools.'
```

Output (trimmed): streamed `{"type":"message_update","assistantMessageEvent":{"type":"text_delta",...,"delta":"PONG"}}` before `message_end` — token-level streaming from a headless run. `--mode rpc` is a full bidirectional JSONL protocol (stdin commands, stdout events); `omp --help` documents both.

**(c) Steer — supported (reproduced).** See the AC-3 probe record below.

**(d) Hooks / lifecycle-event emission — supported.** omp's native RPC mode emits a lifecycle event stream on stdout. Reproduced frames from the steer probe: `agent_start`, `turn_start`, `message_start/end`, `tool_execution_start`, `tool_execution_end`, `turn_end`, `queue_update`, `agent_end`, `prompt_result`, `session_settled`. omp also loads hook/extension files via `--hook=<file>` / `-e <file>` (bundled docs `hooks.md`, `skills/authoring-hooks.md`). Drift note: Claude-style project `hooks/hooks.json` still does not fire under omp — unchanged from the runbook (CDT-550 row 1; the plugin ships no `hooks/` directory).

**(f) Memory — supported (optional column).** omp has a native memory backend: `~/.omp/agent/config.yml` sets `memory.backend: local`; per-project stores exist at `~/.omp/agent/memories/<cwd-slug>/` (observed: `--home-malcolm-.omp`, `--home-malcolm-vibes-describer`); `agent.db` `jobs` records `memory_stage1` jobs as `done`. Plugin-side memory scripts also work under omp at script level (runbook CDT-550 row 5 — schema init, write, LIKE-query, load-session PASS; embeddings path untested).

**(g) Intercom — unverified-after-attempt (optional column).** The plugin's `intercom` skill is discovered and loadable headless:

```
omp -p --thinking low --max-time 240 'Reply with the exact names of every discovered skill whose name or description mentions intercom.'
```

Output: `intercom`. All script assets are present in the loaded marketplace copy (`skills/intercom/`: `intercom.sh`, `probe.sh`, `daemon.sh`, `poller.sh`, `inbox-sidecar.sh`, `docker-compose.yml`). End-to-end Telegram delivery was not probed: `probe.sh` hits the live Bot API by design (SPEC-038) and the daemon/credential state is outside the required set. Verdict `unverified-after-attempt` (normalized from T-05's `partial` at T-10 integration — the index vocabulary has no `partial` value): the surface and assets are verified while the live delivery path is deliberately out of probe scope here, the same treatment as the Claude Code (g) cell.

### omp 18.7.0 — container probe evidence (probed 2026-11-15, G-02 row 1)

Approved image (G-02, row 1 — the only image pulled or run for this host): `docker.io/library/debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2`. `docker pull` of the pinned digest returned `Status: Image is up to date for debian@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2` (digest match). Docker 29.9.3. Every probe is a throwaway `docker run --rm`; no build, no compose, no image reference from a product surface (AC-10). In-container `apt-get install git curl ca-certificates` is the pre-approved set (gate record); `jq`/`sqlite3` are not in it and were not installed.

Model pin (mandatory, same as native): every model-bearing probe passes `--model 'spark-tf/glm5.3-flash-320b-a18b-8x512k-exl3-kv8-dflash2-tp2'`.

Standard recipe (host CLI mounted read-only; host omp state copied to scratch dirs — the live `~/.omp` is never mounted):

```
docker run --rm -v /usr/sbin/omp:/usr/sbin/omp:ro \
  -v /tmp/omp-c627-home/.omp:/root/.omp:ro \
  -v /tmp/omp-c627-run:/root/.omp/run -v /tmp/omp-c627-logs:/root/.omp/logs -v /tmp/omp-c627-cache:/root/.omp/cache \
  -v /tmp/omp-probe-627:/tmp/omp-probe-627 -w /tmp/omp-probe-627 <image> omp …
```

**P-OMP-C0 — binary + version (all container cells inherit this).** Probe command:

```
docker run --rm -v /usr/sbin/omp:/usr/sbin/omp:ro <image> bash -c 'ls -l /usr/sbin/omp; omp --version; ldd /usr/sbin/omp'
```

Output: `omp/18.7.0` — no version drift against the plan lock. The 282 MB ELF needs only `libc.so.6`, `libpthread`, `libdl`, `libm`, `/lib64/ld-linux-x86-64.so.2` (all shipped by `trixie-slim`). No Node runtime is required in the runner image.

**P-OMP-C-A — resume (a): supported.** Probe command (read-only state, host cwd at the identical absolute path, session id from the native probe):

```
docker run --rm … -v /tmp/omp-probe-627:/tmp/omp-probe-627 -w /tmp/omp-probe-627 <image> \
  omp -p --mode json --max-time 120 --model 'spark-tf/glm5.3-flash-320b-a18b-8x512k-exl3-kv8-dflash2-tp2' \
  -r '01a1ddda-7a27' 'What single word did I ask you to reply with earlier in this session? Answer with the word only.'
```

Output (trimmed): `{"type":"session","version":3,"id":"01a1ddda-7a27-760e-bd6c-a123b85f0b5e","timestamp":"2026-11-15T06:17:25.287Z","cwd":"/tmp/omp-probe-627"}` … `"thinking":"Same question third time. Answer PONG."` … `"text":"PONG"`. Session-id source: the `session` frame id and the transcript filename in the mounted `~/.omp/agent/sessions/<cwd-slug>/`; the slug comes from the cwd, so the same-absolute-path mount is what makes the host session resolvable in-container. Restart survival: a session transcript written by one container into a writable mount was resumed by a **new** container — `{"type":"session","version":3,"id":"01a1de23-6268-77dc-9abf-21a6e92d7d0a",…}` then `"text":"RESUME-OK"`.

**P-OMP-C-B — headless streaming (b): supported.** Probe command: `omp -p --mode json --max-time 120 --model 'spark-tf/…' 'Reply with exactly PONG and nothing else. Do not use tools.'` Output (trimmed): `{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"PONG"}}` before `message_end` — token-level streaming from a headless container run, `provider":"spark-tf"`. `--mode rpc` was exercised as the steer driver below (JSONL both directions).

**P-OMP-C-C — Steer (c): supported, reproduced.** See AC-3 § "omp 18.7.0 — container Steer probe record".

**P-OMP-C-D — lifecycle events (d): supported.** Frame census from the container RPC run (151 stdout lines): `message_update` 92, `tool_execution_update` 21, `message_start` 7, `message_end` 7, `turn_start` 3, `turn_end` 3, `tool_execution_start` 2, `tool_execution_end` 2, plus `agent_start`, `queue_update`, `agent_end`, `prompt_result`, `session_settled`. `omp --help` in the container lists `--hook=<file>` ("Load a hook/extension file") and `--mode rpc|rpc-ui` with `--no-ui`. Claude-style project `hooks/hooks.json` still does not fire under omp — unchanged from the runbook (CDT-550 row 1).

**P-OMP-C-E — workflow compatibility (e): see the AC-5 container scores.** Surface discovery: `{"id":"c1","type":"get_available_commands"}` over `omp --mode rpc` returned `available_commands_update` with all 22 `dev-team-edge:*` commands (`adjust-agent` … `worktree`) and 526 command names total, zero EROFS/error lines.

**P-OMP-C-F — memory (f, optional): supported.** Probe command (read-only mounted volume):

```
docker run --rm … <image> bash -c 'omp --version; ls /root/.omp/agent/memories/; grep -n "memory" -A2 /root/.omp/agent/config.yml'
```

Output: `omp/18.7.0`; `--home-malcolm-.omp--`, `--home-malcolm-vibes-describer--`; `memory:` / `  backend: local`. Writes land on the writable agent-dir mount (Fact 2, `container-runner.md`). `sqlite3` is absent from the base image — the plugin-side `.md`/SQLite memory scripts need it installed.

**P-OMP-C-G — Intercom (g, optional): unverified-after-attempt.** Probe command: `omp -p --thinking low --max-time 150 --model 'spark-tf/…' 'Reply with the exact names of every discovered skill whose name or description mentions intercom. Do not use tools.'` Output: `- intercom`. Live Telegram delivery deliberately not probed (SPEC-038: `probe.sh` hits the live Bot API), same limit as the native cell.

**Drift flags vs prior art (read-only check, files not edited).** `docs/runbooks/omp.md` and `docs/internal/omp-host.md` state omp v18.7.0 — matches the probed binary, no version drift. Both files carry **zero** container coverage: `grep -niE 'docker|container|image|volume|mount' docs/runbooks/omp.md docs/internal/omp-host.md` → no matches, so the container facts above are new ground, not a contradiction. Container-specific model drift to record: bare `omp -p` (no `--model`) resolves to `ollama/laya…` in the container too, and there the failure is `"errorMessage":"Unable to connect. Is the computer able to access the url?"` (container netns cannot reach `localhost:11434`) instead of the host's `400 "laya:latest" does not support chat` — pinning is mandatory in the Runner, with a different failure mode.

### mini-swe (documentation-only)

<!-- T-06 owns these rows. Both Runner-type rows filled; each cell states it is documentation-only and cites a vendor-primary doc URL or upstream issue. -->

Host version lock: the plan does not pin a mini-swe version. Documentation reviewed against the latest upstream release, **mini-swe-agent v2.4.6** (GitHub releases, fetched 2026-11-15). No probe was run — every cell is documentation-only and its source is a vendor-primary doc URL (AC-2). The docs do not distinguish a native-process Runner from a container Runner; the Container row therefore carries the same doc statements, plus the container-environment statement where the docs speak to it.

Primary sources (all fetched 2026-11-15):

- CLI usage page, which embeds the full `mini` run-script source: <https://mini-swe-agent.com/latest/usage/mini/>
- FAQ (deliberate limitations, no tools besides bash, independent subprocess actions): <https://mini-swe-agent.com/latest/faq/>
- Agent control flow page, which embeds the full `DefaultAgent` source: <https://mini-swe-agent.com/latest/advanced/control_flow/>
- `mini-extra` reference (subcommands: config, inspect/i/inspector, swebench, swebench-single, programbench): <https://mini-swe-agent.com/latest/reference/run/mini_extra/>
- Releases (v2.4.6 latest): <https://github.com/SWE-agent/mini-swe-agent/releases>

| Capability | Native | Container | Notes |
|---|---|---|---|
| (a) session resume after process death | **unsupported** — documentation-only: the CLI has no resume/continue flag. The full `mini` run-script source on the usage page lists only `-t`, `-c`, `-m`, `-y`, `-l`, `-o`, `--exit-immediately`, `--config`, `--model-class`, `--agent-class`, `--environment-class`; `DefaultAgent.run()` resets `self.messages = []` on every run. Saved trajectories (`.traj.json`) are write-only artifacts browsed by `mini-extra inspect`, not reloadable. Sources: <https://mini-swe-agent.com/latest/usage/mini/> + <https://mini-swe-agent.com/latest/advanced/control_flow/> + <https://mini-swe-agent.com/latest/reference/run/mini_extra/>, checked 2026-11-15 | **unsupported** — documentation-only: same statement as the native row; the docs describe container execution only as an environment class (Docker/Podman/Singularity/Apptainer/Bubblewrap — "works on any system that has a bash shell or uses a container runtime", FAQ) and document no resume mechanism in any environment. Sources: same URLs as native + <https://mini-swe-agent.com/latest/faq/>, checked 2026-11-15 | Fallback named in AC-4 below. |
| (b) headless mode with streaming input and output | **partial** — documentation-only: an unattended, non-interactive run is documented (`-t/--task` supplies the task; `-y/--yolo` skips confirmation; the shipped `interactive.py` source on the usage page explicitly handles "an unattended `--yolo` run, or any run with stdin redirected from /dev/null (CI, a sandbox)"). No streaming stdin/stdout protocol is documented — output is console printing plus a trajectory JSON rewritten each step (`save()` in the run loop). Sources: <https://mini-swe-agent.com/latest/usage/mini/> + <https://mini-swe-agent.com/latest/advanced/control_flow/>, checked 2026-11-15 | **partial** — documentation-only: same statement as the native row; container environments (Docker/Podman/Singularity/Apptainer/Bubblewrap) execute the same single-task runs with the same trajectory-file output. Sources: same URLs + <https://mini-swe-agent.com/latest/faq/>, checked 2026-11-15 | Streaming stdin/stdout: the doc silence is the finding — no protocol page exists in the docs tree. |
| (c) Steer delivery at the next step boundary | **unsupported** — documentation-only: no steer mechanism is documented. The only documented mid-run input path is an interactive Ctrl+C interruption whose comment becomes a user message (`UserInterruption` in `interactive.py`); the docs document no way to deliver a message into a running unattended/headless session. Source: <https://mini-swe-agent.com/latest/usage/mini/> + <https://mini-swe-agent.com/latest/advanced/control_flow/>, checked 2026-11-15 | **unsupported** — documentation-only: same statement as the native row; no steer or injection path is documented for container environments either. Source: same URLs, checked 2026-11-15 | AC-3 note: mini-swe is documentation-only, so the AC-3 reproduced-probe standard cannot be met for it; the cell records the doc state, not a probe. |
| (d) hooks / lifecycle-event emission path | **unsupported** — documentation-only: no hooks system and no lifecycle-event emission are documented. The control-flow page documents the whole step/query/execute_actions loop with no event stream, and the extension mechanism is subclassing — the `query()` docstring says "Override to add hooks." Source: <https://mini-swe-agent.com/latest/advanced/control_flow/>, checked 2026-11-15 | **unsupported** — documentation-only: same statement as the native row; the environment classes (Docker/Podman/Singularity/Apptainer/Bubblewrap) change only where `Environment.execute` runs the subprocess, not the event surface. Source: same URL + <https://mini-swe-agent.com/latest/faq/>, checked 2026-11-15 | |
| (e) workflow compatibility per AC-5 | **partial** — documentation-only: see the mini-swe checklist scores in AC-5 (fail / partial / fail / partial). Sources: <https://mini-swe-agent.com/latest/usage/mini/> + <https://mini-swe-agent.com/latest/faq/>, checked 2026-11-15 | **partial** — documentation-only: same checklist scores as native; the docs state mini runs inside container runtimes (Docker/Podman/Singularity/Apptainer/Bubblewrap) with bash as the only tool, which changes nothing about the Surface/role/card items. Sources: same URLs, checked 2026-11-15 | Scores per item in AC-5 § Checklist scores. |
| (f) memory (optional column) | **unsupported** — documentation-only: no memory feature is documented anywhere in the docs tree. The only persistence is the trajectory file (`-o/--output`, default `last_mini_run.traj.json` in the global config dir). Sources: <https://mini-swe-agent.com/latest/usage/mini/> + <https://mini-swe-agent.com/latest/faq/>, checked 2026-11-15 | **unsupported** — documentation-only: same statement as the native row. Source: same URLs, checked 2026-11-15 | Optional column — not scored as required. |
| (g) Intercom (optional column) | **unsupported** — documentation-only: no messaging, notification, or external-integration surface is documented; the FAQ's limitation list is "no tools other than bash" plus linear history and independent subprocess actions. Source: <https://mini-swe-agent.com/latest/faq/>, checked 2026-11-15 | **unsupported** — documentation-only: same statement as the native row. Source: same URL, checked 2026-11-15 | Optional column — not scored as required. |

## AC-2 — Evidence rules

Verbatim from the plan (AC-2): every cell is `supported` / `unsupported` / `unverified-after-attempt` with evidence — host CLI version, probe date, and source (a probe command with its output, an official doc URL, or an upstream issue). A cell that reads only "unknown" fails review. Probe commands and outputs are recorded in this file, not on disk elsewhere.

## AC-3 — Steer hypothesis

The Claude Code Steer record from the brainstorm is a hypothesis, not a fact. Steer is verified for every host on both Runner types by a reproduced probe: a message sent to a running headless session, with delivery observed at the next step boundary. A `supported` Steer cell without a reproduced probe fails review.

### Steer probe record

<!-- T-03/T-04/T-05 append one probe record per host per Runner type (six total). If a probe disproves the glossary Steer definition, T-11 amends the CONTEXT.md Steer term on this branch and notes the amendment here. -->

#### Grok 1.0.77 — native (reproduced 2026-11-15)

Mechanism: a second ACP `session/prompt` sent while the first turn is running over `grok agent --always-approve stdio`. Setup (scratch dir `/tmp/grok-cdt627-1V1g`):

```
$ grok agent --always-approve stdio            # JSON-RPC on stdin/stdout
→ initialize (id 1) → session/new (id 2)
→ session/prompt (id 3): "Run the shell command `sleep 15 && echo step-done`, then reply exactly STEP-DONE."
  (+6 s, while the sleep tool call is running)
→ session/prompt (id 4): "Additional instruction: when you finish, also reply the word STEERED."
```

Output (verbatim, trimmed):

```
TOOL_CALL: run_terminal_command                      # the sleep step
agent_message_chunk: "STEP-DONE" then "STEERED"     # in file order
{"id":3,"result":{"stopReason":"end_turn",...,"numTurns":2 ... modelCalls":2 ...}}
{"id":4,"result":{"stopReason":"cancelled","_meta":{...,"completionKind":"removedFromQueue"}}}
```

Reading: the mid-turn prompt was not rejected and not dropped — its content reached the model at the next step boundary (after the tool call finished); the final message contains both `STEP-DONE` and `STEERED`, and the run recorded two model calls. The id-4 request itself resolves `cancelled` / `removedFromQueue` because turn ownership stayed with the first prompt — the message was merged into the running turn, not answered as a separate turn. This matches the TUI steer mechanic (`[ui].follow_up_behavior = "steer"` — "injects at the next tool or model safe gap", `05-configuration.md`). Delivery at the next step boundary: reproduced. This is the ACP/stdio route; the single-turn headless route (`grok -p`) has no documented mid-run injection surface (see (b) above).

#### Grok 1.0.77 — container (reproduced 2026-11-15)

Same mechanics reproduced in-container (P-GK-CTR-3c, full transcript under the Grok container probe transcripts above): ACP `grok agent stdio` in a throwaway `docker run --rm` debian container (approved digest), client capabilities `terminal: false`; a second `session/prompt` was sent while the `sleep 15` tool step was executing. The steer entered the queue mid-tool (`_x.ai/queue/changed` with the steer text while `runningPromptId` belonged to prompt 3), was consumed at the next step boundary after the tool completed (exit 0), and shaped the final yield — the assistant message streamed `STEP-DONE\nSTEERED-CTR`; prompt 3 resolved `end_turn` with `numTurns: 2`, `modelCalls: 2`; the id-4 request resolved `cancelled` / `removedFromQueue` (merged into the running turn). The definition holds in-container; no glossary disproof from this probe. Adapter constraint recorded: `terminal: false` is required (with `terminal: true` and no client-side `terminal/*` implementation the turn stalls at the agent's `terminal/create` request — P-GK-CTR-3b).

### omp 18.7.0 — native Steer probe record (reproduced, 2026-11-15)

Setup: launch omp in RPC mode (a long-running headless session), give it a 45-second bash job, inject a steer while the bash tool runs, and check that the message is delivered at the next step boundary and shapes the final reply before the session settles.

Probe command (one compound command, no script file):

```
cd /tmp/omp-probe-627 && ( sleep 3; \
  printf '%s\n' '{"id":"p1","type":"prompt","message":"Use the bash tool to run exactly: sleep 45 && echo SLEPT. After the tool result returns, reply DONE."}'; \
  sleep 28; \
  printf '%s\n' '{"id":"s1","type":"steer","message":"Steer probe: append the word STEERED-OK to your final reply."}'; \
  sleep 120 ) | omp --mode rpc --auto-approve --max-time 240 --model 'spark-tf/glm5.3-flash-320b-a18b-8x512k-exl3-kv8-dflash2-tp2'
```

Key output frames (trimmed):

1. Steer accepted while the agent was mid-tool: `{"type":"queue_update","steering":["Steer probe: append the word STEERED-OK to your final reply."],"followUp":[]}` then `{"id":"s1","type":"response","command":"steer","success":true}`.
2. Delivered at the next step boundary — a user message entered the transcript mid-run right after the tool boundary: `{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"Steer probe: append the word STEERED-OK to your final reply."}],"steering":true,...},"messageId":"msg-4"}`. omp even backgrounded the long bash early to handle the incoming message ("Backgrounded early to handle an incoming message").
3. Delivery shaped the final yield: the assistant's final message was `"text":"DONE STEERED-OK"`, followed by `{"type":"prompt_result","id":"p1","agentInvoked":true,"status":"completed","sessionSettled":true}` and `{"type":"session_settled"}`.

Mechanism the Host adapter would call: the RPC command `{"type":"steer","message":...}` (protocol doc: `rpc.md` in the upstream repo, command schema "Prompting"); a mid-run `prompt` can also carry `streamingBehavior: "steer"`. Delivery is at a step boundary — omp routes the message into the live run and processes it before the terminal yield, matching the glossary Steer definition. No glossary disproof.

#### omp 18.7.0 — container Steer probe record (reproduced, 2026-11-15)

Same protocol as the native probe, run inside the G-02 row-1 image (`debian:trixie-slim@sha256:a72b4433…`) with the host CLI mounted read-only, the omp state copied to a writable scratch mount, and the cwd mounted at the identical absolute path `/tmp/omp-probe-627`. Model: `spark-tf/glm5.3-flash-320b-a18b-8x512k-exl3-kv8-dflash2-tp2`.

Probe command (one compound command, stdin piped into the container with `-i`):

```
cd /tmp && ( sleep 3; \
  printf '%s\n' '{"id":"p1","type":"prompt","message":"Use the bash tool to run exactly: sleep 45 && echo SLEPT. After the tool result returns, reply DONE."}'; \
  sleep 28; \
  printf '%s\n' '{"id":"s1","type":"steer","message":"Steer probe: append the word STEERED-CT to your final reply."}'; \
  sleep 150 ) | docker run -i --rm -v /usr/sbin/omp:/usr/sbin/omp:ro -v /tmp/omp-c627-rw/.omp:/root/.omp \
  -v /home/malcolm/.omp/natives:/root/.omp/natives:ro -v /tmp/omp-probe-627:/tmp/omp-probe-627 -w /tmp/omp-probe-627 \
  docker.io/library/debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 \
  omp --mode rpc --auto-approve --max-time 240 --model 'spark-tf/glm5.3-flash-320b-a18b-8x512k-exl3-kv8-dflash2-tp2'
```

Key output frames (verbatim, trimmed; 151 lines total):

1. Steer accepted mid-tool: `{"type":"queue_update","steering":["Steer probe: append the word STEERED-CT to your final reply."],"followUp":[]}` then `{"id":"s1","type":"response","command":"steer","success":true}`.
2. The running bash step was cut short to take the message: `{"type":"tool_execution_end","toolCallId":"call_630656b71e592c254c8eadb9","toolName":"bash","result":{"content":[{"type":"text","text":"Backgrounded early to handle an incoming message; the command ke…` — then `turn_end`, `{"type":"queue_update","steering":[],"followUp":[]}`, `{"type":"turn_start"}`.
3. Delivered at the step boundary as a user message: `{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"Steer probe: append the word STEERED-CT to your final reply."}],"steering":true,…},"messageId":"msg-4"}`.
4. Delivery shaped the final yield: `"text":"DONE STEERED-CT` … then `{"type":"prompt_result","id":"p1","agentInvoked":true,"status":"completed","sessionSettled":true}` and `{"type":"session_settled"}`.

Reading: identical frame sequence to the native probe — accepted mid-turn, injected at the tool/turn boundary, consumed before the terminal yield, turn not aborted. The container adds no constraint on the Steer path (the RPC stdin is a pipe; no tty is needed). Delivery at the next step boundary: reproduced in-container. No glossary disproof, so the T-11 amendment exception is not triggered by this probe either.

**Claude Code — native Runner** (claude 2.1.325, probe 2026-11-15): reproduced. Message injected into a running headless stream-json session's stdin while a Bash tool call (`sleep 25 && echo SLEEP2-DONE`) was executing; delivery observed at the next step boundary — the turn's final assistant text after the sleep contained the injected token verbatim: ``"`SLEEP2-DONE` printed (exit 0, run in the background) — STEER-RECEIVED-47"``. Full transcript: P-CC-C above. The glossary Steer definition (message delivered into a running session at the next step boundary) matches the observed behavior; no amendment indicated from this probe.

**Claude Code — container Runner** (claude 2.1.325 inside the G-02-approved throwaway image, probe 2026-11-15): reproduced. P-CON-STEER — a stream-json session over a container-internal fifo (write end held open so no premature EOF); turn 2 started a `sleep 20 && echo S2-DONE` Bash tool call; the steer message was injected 3 s after turn 2, while the tool call was still pending. Delivered at the next step boundary — the turn's final assistant text contained the injected token verbatim: `TURN2-DONE STEER-CON8-44`. The session transcript carries the same queue mechanic as native (`enqueue` of the steer, then `"reason":"absorbed_mid_turn"`). Matches the glossary Steer definition; no amendment indicated from this probe.

#### T-11 — Steer adjudication (AC-3) — ic5

**Verdict: glossary Steer definition confirmed by six reproduced probes (three hosts × native + container Runner); no amendment needed.**

Definition adjudicated against: the brainstorm record's Steer term — "a message delivered to a running session at its next step boundary (avoid: interrupt, nudge)" (`/.claude/plans/2026-11-11-brainstorm-control-plane.md:186`, machine `vibes/claude-dev-team`; also line 124: "A correction is a steer delivered at the next step boundary. It does not interrupt a turn."), and the AC-3 wording itself (this plan, line 48: "Steer delivery at the next step boundary"). CONTEXT.md on this branch does not yet carry the Steer term — the glossary timing was ruled in-ticket (11 confirmed terms) and the write-back belongs to CDT-632 — so the brainstorm record is the SoT compared against. No probe contradicted it, so no CONTEXT.md Steer amendment was made (exception b not triggered).

Probe-by-probe comparison (native Runner, reproduced 2026-11-15; container Runner rows follow the same order):

| Probe | Delivery observed | Matches definition |
|---|---|---|
| Claude Code 2.1.325 — P-CC-C (`docs/internal/control-plane/host-capability-matrix.md:58-70`, probe record :302) | Steer message written to the running stream-json session's stdin mid-turn; consumed at the next step boundary after the `sleep 25` tool step finished; final reply carried `STEER-RECEIVED-47`. Turn not interrupted. | yes |
| Grok 1.0.77 — ACP steer (`docs/internal/control-plane/host-capability-matrix.md:259-278`) | Mid-turn `session/prompt` (id 4) during a running tool call; content delivered at the next boundary (`STEP-DONE` then `STEERED` in one final message, `numTurns:2`, `modelCalls:2`); the id-4 request resolves `cancelled`/`removedFromQueue` because turn ownership stayed with prompt 1 — merged into the running turn, not a separate one. | yes |
| omp 18.7.0 — RPC steer (`docs/internal/control-plane/host-capability-matrix.md:280-300`) | `{"type":"steer"}` accepted mid-tool (`queue_update` `steering:[…]`, response `success:true`); delivered as a `steering:true` user message at the tool-result boundary (`message_end`, `msg-4`); shaped the final yield (`"DONE STEERED-OK"`) before `prompt_result`/`session_settled`. | yes |
| Claude Code 2.1.325 — container P-CON-STEER (`docs/internal/control-plane/host-capability-matrix.md:112-126`) | Steer message written to a container stream-json session's stdin 3 s after turn 2, while the `sleep 20 && echo S2-DONE` Bash tool call was pending (fifo write end held open); the transcript carries `enqueue` then `"reason":"absorbed_mid_turn"`; the final reply carried `TURN2-DONE STEER-CON8-44`. Turn not interrupted. | yes |
| Grok 1.0.77 — container ACP steer, P-GK-CTR-3c (`docs/internal/control-plane/host-capability-matrix.md:295-317`) | Mid-turn `session/prompt` (id 4) during the running `sleep 15` tool step, client capabilities `terminal: false`; the `_x.ai/queue/changed` entry was consumed at the next boundary; the final message carried `STEP-DONE` and `STEERED-CTR` (`numTurns:2`, `modelCalls:2`); the id-4 request resolved `cancelled`/`removedFromQueue`. | yes |
| omp 18.7.0 — container RPC steer, P-OMP-C-C (`docs/internal/control-plane/host-capability-matrix.md:563-587`) | `{"type":"steer"}` accepted mid-tool in the G-02 row-1 image (`queue_update` `steering:[…]`, response `success:true`); delivered as a `steering:true` user message at the step boundary (`message_end`, `msg-4`); shaped the final yield (`"DONE STEERED-CT`) before `prompt_result`/`session_settled`. | yes |

All six probes — three hosts on the native Runner and the same three hosts on the container Runner — delivered the injected message at the next step boundary without interrupting the running turn. The container added no constraint on the Steer path. The glossary Steer definition is confirmed on both Runner types; no probe disproved it, so no CONTEXT.md Steer amendment is needed. Two notes for the record:

1. **Container Runner:** G-02 is approved (T-02, row 1 image). The three container probes landed and are adjudicated above against the same definition: Claude Code P-CON-STEER, Grok P-GK-CTR-3c, omp P-OMP-C-C — all reproduced, all `yes`.
2. **mini-swe:** documentation-only, Steer recorded `unsupported` (`docs/internal/control-plane/host-capability-matrix.md:239`). That is an absence of the capability, not a disproof of the definition — no amendment follows from it.

## AC-4 — Resume path per host

For every host, name exactly one of the two paths:

- Resume mechanism — the exact CLI flag and the session-id source the Host adapter would call.
- Fallback — step re-run from the last lifecycle checkpoint (control plane Option C+ (CDT-626)).

A host row without one of these two named paths fails review.

<!-- T-03/T-04/T-05 record resume or fallback per host; T-06 records the mini-swe path; T-10 finalized the set — one named path per host, matrix host order. -->

### Claude Code (native Runner) — resume path (AC-4)

Resume mechanism. `claude -p --resume <session-id>` (also interactive `-r` picker and `-c/--continue` for the most recent session in the directory). Session-id source: the `system/init` event of the stream-json output (present on every headless session start), mirrored on disk at `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`. Verified by probe P-CC-A: session killed with SIGKILL, resumed by id, state intact (probe 2026-11-15, claude 2.1.325). Container Runner: the same flag and session-id source work across container death (P-CON-A, 2026-11-15) — the transcript lives on the host volume `~/.claude/projects/`, so resume needs `~/.claude` mounted read-write, no copy step.

### Grok 1.0.77 — resume path (AC-4)

Resume mechanism. Flag: `--resume <SESSION_ID_OR_TITLE>` (session id or title; UUID-shaped values always take the id path). Session-id source: the `sessionId` field of the headless `--output-format json` result, or the `end` event under `streaming-json`. Session state persists per working directory under `~/.grok/sessions/`. Companion flags: `-c/--continue` (newest session in cwd), `--fork-session` (resume into a new session id). Probed across process death on 2026-11-15 (evidence under the Grok matrix rows). Checkpoint fallback not required.

### omp 18.7.0 — resume path (AC-4)

Resume mechanism — the Host adapter calls `-r, --resume=<value>` (by session-id prefix, session path, or picker) or `-c, --continue` for the previous session. Session-id source: session files live at `~/.omp/agent/sessions/<cwd-slug>/<UTC-timestamp>_<uuid>.jsonl` (override the root with `--session-dir`); the same ids index the `threads` table in `~/.omp/agent/agent.db`. Verified reproduced — see cell (a) evidence.

- CLI version: omp 18.7.0. Probe date: 2026-11-15.

### mini-swe — resume path (AC-4, documentation-only)

Fallback — step re-run from the last lifecycle checkpoint (control plane Option C+ (CDT-626)). The docs name no resume mechanism: the full `mini` CLI source carries no resume/continue flag (<https://mini-swe-agent.com/latest/usage/mini/>), `DefaultAgent.run()` starts every run from an empty message list (<https://mini-swe-agent.com/latest/advanced/control_flow/>), and `mini-extra` offers only config / inspect / benchmark subcommands — no session reload (<https://mini-swe-agent.com/latest/reference/run/mini_extra/>). Date checked: 2026-11-15.

## AC-5 — Workflow-compatibility checklist

Score capability (e) against this checklist. Each item gets pass/fail/partial per host per Runner type, with AC-2 evidence. Memory and Intercom are excluded from the required set.

Checklist items:

1. Run a Surface headless.
2. Spawn or inline the roles.
3. Write decision-cards.
4. Use worktrees.

### Checklist scores

<!-- T-03/T-04/T-05 append per-host scores here; T-10 finalized — host order matches the AC-1 matrix; the container scores landed 2026-11-15 (G-02 row 1). -->

#### Claude Code — native Runner checklist scores (probed 2026-11-15)

**Claude Code — native Runner** (claude 2.1.325, probe 2026-11-15). One headless run (`claude -p --permission-mode bypassPermissions --max-turns 15 "<five-step prompt>"`) exercised all items; its reply, verbatim:

> 1. `/status worktree`: one worktree — `CDT-627` on `feat/CDT-627`, lock `FRESH`, age 2h31m, HEAD `5edb490` (v1.28.20).
> 2. The `dev-team:finder` agent replied `READY`.
> 3. Wrote `.claude/autopilot/decision-cards/probe-cdt627-e.md` with the single line `CDT-627 probe card`.
> 4. `ensure` printed `/home/malcolm/vibes/claude-dev-team/.worktrees/cdt627-probe-e`; `release` printed no path (empty output, exit 0), and the worktree and its `feat/cdt627-probe-e` branch are gone.
> 5. The `ic4` count is `399`.

| Checklist item | Score (native) | Evidence |
|---|---|---|
| 1. Run a Surface headless | pass | The plugin `/status worktree` Surface ran in `claude -p` mode and returned real worktree state (line 1 of the run reply above). |
| 2. Spawn or inline the roles | pass | Task-tool spawn of the plugin's `dev-team:finder` agent in headless mode returned `READY` (line 2). |
| 3. Write decision-cards | pass | Session wrote `.claude/autopilot/decision-cards/probe-cdt627-e.md`; file verified on disk (`cat` → `CDT-627 probe card`), then removed — probe artifact only. |
| 4. Use worktrees | pass | Headless session ran `bash skills/worktree-lib.sh ensure cdt627-probe-e` (printed the worktree path) and `release cdt627-probe-e` (exit 0; `git worktree list` afterward shows only the main repo and CDT-627 worktrees). |

**Claude Code — container Runner checklist scores** (claude 2.1.325 inside the G-02-approved throwaway image, probe 2026-11-15; evidence in P-CON-C1..C3 and P-CON-B above):

| Checklist item | Score (container) | Evidence |
|---|---|---|
| 1. Run a Surface headless | pass | `/status worktree` invoked through the Skill tool (`dev-team:status`, args `worktree`) inside a container headless session returned the real worktree summary (P-CON-C1). |
| 2. Spawn or inline the roles | pass | Task-tool spawn of the plugin's `dev-team:finder` agent from a container headless session returned `READY` (P-CON-C2). |
| 3. Write decision-cards | pass | Container headless session wrote `.claude/autopilot/decision-cards/probe-cdt627-con.md`; file verified on the host volume after the container exited (P-CON-C3). |
| 4. Use worktrees | pass | Container headless session ran `pwd` → the identical worktree absolute path and `git branch --show-current` → `feat/CDT-627` (P-CON-B). |

#### Grok 1.0.77 — native (probe date 2026-11-15)

| Item | Score | Evidence |
|---|---|---|
| 1. Run a Surface headless | pass | `grok -p "/dev-team-edge:status" --always-approve --output-format json` from the CDT-627 worktree → `stopReason: "end_turn"`; the session resolved the plugin root and executed the `/status` sequence (standup → metrics → worktree). The dev-team surfaces are listed to headless runs in the `available_commands` payload of `--output-format streaming-json`. |
| 2. Spawn or inline the roles | pass | Inline roles probed: one headless reply carried a `PM:` line and a `TL:` line about the repository (scratch-repo probe, session `01a1dde8-1413-7ac0-beeb-9c2bb24644c6`). Native subagent spawning also exists (`spawn_subagent` tool in the headless tool list, `--agents <JSON>`, `--no-subagents` flag; doc `16-subagents.md`) — not separately probed; the checklist requires spawn or inline. |
| 3. Write decision-cards | pass | Headless session ran the bundled writer `bash skills/autopilot/append-card.sh orchestrate CDT627PROBE ship-choice proceed auto null 80 null run-probe 1 5 grok probe-card` (exit 0) and printed the JSONL card it wrote to `<repo>/.claude/autopilot/CDT627PROBE.jsonl` (schema_version 1, gate ship-choice, decision proceed, confidence 80). |
| 4. Use worktrees | pass | `grok -p "Print only the absolute path of the current working directory and the current git branch." --always-approve --worktree cdt627-probe` in a scratch repo → session ran inside `/home/malcolm/.grok/worktrees/tmp-grok-cdt627-scr/cdt627-probe` on branch `master`; removed after with `grok worktree rm cdt627-probe`. Caveat: grok's native `--worktree` lands under `~/.grok/worktrees/`, not `.worktrees/<slug>` inside the repo — SPEC-016 placement for plugin-managed worktrees goes through `git worktree add` via the host shell tool (available; not separately probed here). |

Container-Runner checklist scores (grok 1.0.77 in container, probe date 2026-11-15, approved image `debian:trixie-slim@sha256:a72b…6b2`; probes P-GK-CTR-5/5b/6 above):

| Checklist item | Score (container) | Evidence |
|---|---|---|
| 1. Run a Surface headless | pass | `/dev-team-edge:status worktree` executed in-container from the ro-mounted marketplace cache; the session resolved the plugin (v1.28.20) and returned the real read-only status report (P-GK-CTR-6). |
| 2. Spawn or inline the roles | pass | Inline roles: one headless in-container reply carried `PM:` and `TL:` lines about the scratch repo (P-GK-CTR-5). |
| 3. Write decision-cards | pass | The bundled `append-card.sh` ran in-container and wrote a full schema card (`actor: grok`, `decision: proceed`) to `.claude/autopilot/CDT627CTR.jsonl` in the mounted scratch repo; card JSON verbatim in P-GK-CTR-5 above. |
| 4. Use worktrees | pass | `git worktree add .worktrees/probe-ctr -b probe-ctr` inside the container put the worktree at `.worktrees/<slug>` inside the project root (SPEC-016 layout) and grok ran inside it at the same absolute path (`/tmp/grok-ctr-wt/.worktrees/probe-ctr`, branch `probe-ctr`) (P-GK-CTR-5b). Caveat: bind-mounted host-uid repos need `git config --global --add safe.directory` when the container runs as root. |

#### omp 18.7.0 — native Runner checklist scores (probed 2026-11-15)

Probes run headless (`omp -p`) in the throwaway repo `/tmp/omp-probe-627`, model `spark-tf/glm5.3-flash-320b-a18b-8x512k-exl3-kv8-dflash2-tp2`, `--auto-approve`.

1. **Run a Surface headless — pass.** `/dev-team-edge:status worktree` executed in print mode and returned the full status report (epics, outcomes, worktrees views, `plugin-dir.sh` resolution line: "marketplace `cold-dark-void`, v1.28.20 preferred over same-version cache"). All 22 `dev-team-edge:*` commands are discovered headless — probe: `{"id":"c1","type":"get_available_commands"}` over `omp --mode rpc` returned the `available_commands_update` frame listing `dev-team-edge:adjust-agent` … `dev-team-edge:worktree`.
2. **Spawn or inline the roles — pass.** One headless run used the `task` tool to launch a subagent that returned `{"status":"ready","role_ack":"ROLEOK"}`; the driver model echoed it back as its item-1 evidence.
3. **Write decision-cards — pass.** Same run located the marketplace clone and executed its `skills/autopilot/append-card.sh` (exit 0) after the model adapted to the script's real contract (positional args, integer confidence, `decided_by` ∈ auto|user — the model self-corrected the probe's intentionally loose args). Last line of `/tmp/omp-probe-627/.claude/autopilot/PROBE-627.jsonl` starts `{"schema_version":1,"type":"autopilot_decision","ts":"2026-11-15T06:33:26Z","run_id":"omp-probe-627",...}` — verified on disk.
4. **Use worktrees — pass.** Same run created `.worktrees/probe-wt` on branch `probe-wt-branch` inside the project root (SPEC-016 layout). `git worktree list` output, verified on disk:

```
/tmp/omp-probe-627                     0000000 [master]
/tmp/omp-probe-627/.worktrees/probe-wt 0000000 [probe-wt-branch]
```

Container-Runner checklist scores (omp 18.7.0, probe 2026-11-15, image `debian:trixie-slim@sha256:a72b4433…`, G-02 row 1; `apt-get install git curl ca-certificates` inside the throwaway container, model `spark-tf/glm5.3-flash-320b-a18b-8x512k-exl3-kv8-dflash2-tp2`):

| Checklist item | Score (container) | Evidence |
|---|---|---|
| 1. Run a Surface headless | pass | `omp -p --auto-approve '/dev-team-edge:status worktree'` in the container, cwd mounted at the identical absolute path `/home/malcolm/vibes/claude-dev-team/.worktrees/CDT-627`, returned the real standup/epic/metrics/worktree report — "`worktree-lib.sh status` exited 0 with no output — one worktree exists (`.worktrees/CDT-627`, this session)". Discovery is complete: RPC `get_available_commands` listed all 22 `dev-team-edge:*` commands. Caveat (image toolchain, not host): the engines that need `jq` degraded — `rollup: jq not found; cannot aggregate metrics`, `dag-lib ready-set` → exit 64 `error: jq is required but not found in PATH`. |
| 2. Spawn or inline the roles | pass | One headless container run used the `task` tool to spawn a subagent; its reply came back verbatim: `ROLEOK-CT`. (First attempt at items 1+2+3+4 in one run hit `--max-time` — `Deadline exceeded` — so items were split across runs.) |
| 3. Write decision-cards | partial | The container ran the bundled writer: `bash /home/malcolm/.claude/plugins/marketplaces/cold-dark-void/skills/autopilot/append-card.sh orchestrate C627C ship-choice proceed auto null 80 null omp-c627c-container 1 5 probe container-probe` → `error: jq not found; cannot write decision card`, `exit=64`, and no `.claude/autopilot/C627C.jsonl` on the host. The script is reachable and executable in-container; the approved image ships no `jq`, and `jq` is outside the pre-approved apt set (git, curl, ca-certificates) so it was not installed. Runner-image need (AC-6 Fact 4). |
| 4. Use worktrees | pass | SPEC-016 contract exercised directly in-container against the repo mounted at its own absolute path `/tmp/omp-c627-repo`: `bash …/skills/worktree-lib.sh ensure c627c` printed `/tmp/omp-c627-repo/.worktrees/c627c` (exit 0); inside it `pwd` → `/tmp/omp-c627-repo/.worktrees/c627c`, branch `feat/c627c`, `git rev-parse --show-toplevel` → the same path; `release c627c` exited 0 and the host confirms the worktree and branch are gone. Prerequisite: the container runs as root against a uid-1000 repo, so git's ownership guard fires — `fatal: detected dubious ownership in repository at '/tmp/omp-c627-repo'` — cleared by `git config --global --add safe.directory <path>` (or by running the container `--user`-matched). |

Probe hygiene (recorded because it is a container-runner property, not an omp one): the default container user is root, so files the agent writes into a bind-mounted host repo are root-owned — the host user then cannot clean them (`error: failed to delete '/tmp/omp-c627-repo/.worktrees/c627c': Permission denied`); removal needed a root container. In one run the model also created a `jq -> /tmp/c627c-bin/jq` symlink in the repo on its own initiative to work around the missing `jq` (target absent after `--rm`; symlink removed).

#### mini-swe — checklist scores (documentation-only, checked 2026-11-15)

Scored against the docs only (no probe — mini-swe is documentation-only). Host: mini-swe-agent v2.4.6 docs.

| Checklist item | Score (both Runner types, per docs) | Evidence (documentation-only) |
|---|---|---|
| 1. Run a Surface headless | fail | The docs document a single-task agent run (`-t/--task`, `-y/--yolo`) with no command- or skill-discovery surface — there is nothing to run the plugin's Surfaces through. Source: <https://mini-swe-agent.com/latest/usage/mini/>. |
| 2. Spawn or inline the roles | partial | The docs describe one agent with completely linear history and no subagent machinery (FAQ: "no tools other than bash", "completely linear history"). Roles could only be prompted inline, which the docs neither document nor forbid. Source: <https://mini-swe-agent.com/latest/faq/>. |
| 3. Write decision-cards | fail | No decision-card or structured-report mechanism is documented; the only file output is the trajectory JSON (`-o/--output`). Source: <https://mini-swe-agent.com/latest/usage/mini/>. |
| 4. Use worktrees | partial | The docs state bash is the only tool and every action is an independent subprocess (`subprocess.run`), so `git worktree` commands are mechanically runnable — but no worktree-specific support is documented. Source: <https://mini-swe-agent.com/latest/faq/>. |

## T-10 — Integration note (2026-11-15)

Integrator: ic4 (T-10). Checked the file against the plan contract (AC-1/AC-2 completeness, AC-4 named paths, AC-5 checklist) and T-01's index conventions. No probe was re-run; every verdict and evidence item is the owning task's (T-03/T-04/T-05/T-06). Findings and fixes:

1. **Completeness (AC-1/AC-2):** all 56 host × Runner × capability cells are filled (4 hosts × 2 Runner types × 7 capabilities). Scan evidence: `grep -n '|[[:space:]]*|[[:space:]]*|' host-capability-matrix.md` → no matches (no empty cells); `grep -niE '\b(unknown|tbd|todo)\b' host-capability-matrix.md` → one hit only, the verbatim AC-2 rule quote in § AC-2. Refresh (2026-11-15): the pending marker is gone from every cell. All 28 container cells carry a verdict — the three probed hosts' container halves are now evidence-backed (T-03/T-04/T-05 probed 2026-11-15 in the G-02 row-1 image), and mini-swe's container column is documentation-only per T-06. Container-column scan (`awk -F'|' '/^\| \(/ {print NR": "$4}'` over the four matrix tables): 28 cells, each opening with `supported` (17: CC a-e, Grok a-e+g, omp a-f), `unsupported` (6: Grok f, mini-swe a/c/d/f/g), `unverified-after-attempt` (3: CC f+g, omp g), or mini-swe (b)/(e), which keep T-06's documentation-only `partial` wording — see item 6.
2. **Container-marker normalization:** the three probed hosts' container cells used three wordings ("blocked on G-02 — T-02 approval pending" (CC), "waits on G-02" (Grok), "container half waits on G-02 (T-02 approval); not probed 2026-11-15" (omp)). Normalized to one marker — "waits on G-02 — T-02 approval pending" — with omp's "; container half not probed 2026-11-15" kept. Wording only; no evidence content changed. Refresh 2026-11-15: that marker is retired — the landed container probes replaced it with real verdicts in all 28 container cells (see item 1), so the file no longer contains the marker string.
3. **Evidence-field format (three probed hosts):** every native cell now carries host CLI version + probe date + source. Grok's cells lacked per-cell version/date (section preamble only) — added inline (`grok 1.0.77, probed 2026-11-15`) and bolded the verdict words. CC already carried them inline. omp carries them per cell in the row's Notes column (kept there; no duplication introduced). Verdict vocabulary across the three hosts' cells is now uniform (`supported` / `unsupported` / `unverified-after-attempt`, bold).
4. **AC-4:** all four host rows name exactly one path — CC, Grok, omp name the resume mechanism (CLI flag + session-id source each); mini-swe names the checkpoint fallback (control plane Option C+ (CDT-626)). No cloud-auth row exists in the matrix and none is required: the plan's AC-1 host list is the four hosts, and cloud auth is CDT-632 scope (reads `credentials.md`). Section structure normalized to one `###` per host in matrix host order — the CC entry was a floating bullet and Grok was a bullet under "### Resume paths"; both are now H3 sections with content verbatim.
5. **AC-5:** all four hosts are fully scored for the native/docs Runner (CC, Grok, omp: four items each, all `pass`, with evidence; mini-swe: fail / partial / fail / partial per docs — one table scores both Runner types since mini-swe is documentation-only). The AC-5 intro states memory and Intercom are excluded from the required set — verified. Refresh (2026-11-15): those pending lines are gone — each of the three probed hosts now carries a Container-Runner checklist score table backed by container probes (CC: four `pass`, P-CON-C1..C3 + P-CON-B; Grok: four `pass`, P-GK-CTR-5/5b/6; omp: items 1, 2, 4 `pass` and item 3 `partial` — the approved image ships no `jq`, so `append-card.sh` exits 64, a runner-image toolchain need (AC-6 Fact 4), not a host limit). AC-5 now carries 28 item scores: 12 container + 12 native + 4 mini-swe docs-only. Host blocks reordered to matrix host order (the CC block sat after mini-swe) and set to `####` (omp and mini-swe were `###`; the CC block had no heading — "#### Claude Code — native Runner checklist scores (probed 2026-11-15)" added). Content moved verbatim, no evidence edited.
6. **Vocabulary deviation left in place (flagged for T-12):** mini-swe's documentation-only cells (b) and (e) read `partial`, which is not one of the three index verdicts — left as T-06 wrote them: (b) reflects a genuine docs split (unattended run documented, streaming undocumented) and (e) is the AC-5 score aggregate, where AC-5's own vocabulary is pass/fail/partial. omp (g) was normalized from `partial` to `unverified-after-attempt` (one of the three probed hosts; rationale preserved verbatim, same treatment as the CC (g) cell).
7. **Read-only cross-checks outside this file (not edited):** refresh 2026-11-15 — `container-runner.md` AC-6 five-facts sections are now filled per host with verdicts and evidence (T-03/T-04/T-05, probed 2026-11-15); the empty `- Verdict:` / `- Evidence:` template lines that remain under each fact are unused scaffolding, and that file's preamble line "Container work waits on the AC-10 approval gate (T-02 / G-02)" is superseded by the gate-state line below it. Refresh (2026-11-15, T-12 gate check): both open items are closed — `container-runner.md` § "Grok container credentials" is filled (T-04: (a) `cached_token` from the ro-mounted `~/.grok/auth.json`, (b) mounted file paths, (c) restart survival over nine containers, plus the host-side one-time operator step), and `credentials.md` § "Container-Runner half — AC-9 grid" is re-synthesized from the landed container rows. `docs/runbooks/omp.md` / `docs/internal/omp-host.md` drift is flagged inside the omp section (T-05), not edited there.

Final cell count (refresh 2026-11-15): AC-1 matrix = 56 cells (4 hosts × 2 Runner types × 7 capabilities), every cell carrying a verdict. AC-5 checklist = 28 item scores (CC/Grok/omp: 4 native + 4 container each = 24; mini-swe: 4 docs-only scores in one column covering both Runner types). AC-4 = 4 named host paths. AC-3 = six reproduced Steer probes recorded — three native (CC P-CC-C, Grok ACP, omp RPC) and three container (CC P-CON-STEER, Grok P-GK-CTR-3c, omp container RPC). The T-11 adjudication block in this file adjudicates all six probes: its table carries the three native rows and the three container rows (P-CON-STEER, P-GK-CTR-3c, P-OMP-C-C), and its note 1 records the G-02 approval and the landed container probes. T-12 verified the block covers six probes (2026-11-15).

**T-10 refresh pass — 2026-11-15 (ic4).** The container halves of T-03/T-04/T-05 landed; this pass refreshed the stale notes above (items 1, 2, 5, 7, the AC-5 § Checklist scores ownership comment, and the count paragraph). G-02 gate state as recorded in the repo: APPROVED for rows 1 and 3 on 2026-11-15 — row 1 `docker.io/library/debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2` (the probe base of every container cell in this file, with `apt-get install git curl ca-certificates` pre-approved) and row 3 `docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea` (AC-8 build probe only, `node-agent-build-probe.md`). The `node` image was **not** approved and is referenced nowhere in this file (`grep -niE 'n[o]de[:0-9]|library/n[o]de'` → no matches). No probe was re-run and no cell verdict, transcript, quote, or owner comment content was changed by this pass; only stale T-10 wording was refreshed.
