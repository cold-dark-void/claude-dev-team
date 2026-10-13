# Runbook: oh-my-pi (omp) host

Run the dev-team plugin under omp (oh-my-pi). omp v18.7.0 loads Claude
plugins through its built-in Claude plugin loader. Support is opt-in.

See also: [Setup & Configuration](../setup.md),
[Host tool map](../host-tool-map.md).

## Enable

Set the provider in your omp config:

```
omp config set enabledProviders '["claude-plugins"]'
```

If you do not want this in the default profile, scope the setting to an
omp profile and run with `--profile <name>`. The CDT-550 dogfood used an
isolated profile (`--profile dogfood550`) and left the default profile
untouched.

## Verify

1. Start omp with your profile.
2. Check skill and agent discovery: the profile log lists the dev-team
   skills (`council`, `epic`, `kickoff`, `memory-store`, …) and injects
   the roster agents into the system prompt.
3. Commands use the prefix `/dev-team-edge:<name>`. Skills use
   `/skill:<name>`.

## Versions

The plugin version follows the Claude plugin registry. omp does not pin
its own copy. Update the plugin through your normal Claude plugin flow.

## Undo

Remove `claude-plugins` from `enabledProviders`. For example:

```
omp config set enabledProviders '[]'
```

Set the key back to its previous value if you had one.

## Known limits

Verified on omp v18.7.0 (CDT-550 dogfood, 2026-10-13):

- Skills, commands, and agents load and expand. Discovery works.
- Tool schemas did not attach in the trial. `omp --mode text` with
  OpenAI-compatible providers (local ollama) never issued a real tool
  call; `/orchestrate`, `/council`, `/review-and-commit`, and
  `/ci-watch` failed at skill invocation. Gate flows are unproven until
  you run a tool-capable backend.
- Claude-style hooks did not fire under omp. The plugin ships no
  `hooks/` directory; hooks stay opt-in through the transcript-mirror
  skill copy.
- Memory store and recall script paths work (schema init, write,
  query, load-session). The embeddings path is untested.

## Approval mode

omp has no `AskUserQuestion`. Autopilot gates cannot be answered on
omp. Do not run `--autopilot` on omp until the gates are validated with
a tool-capable backend.

---

## Dogfood matrix (2026-10-13)

CDT-550 results on omp v18.7.0, dev-team plugin loaded, local ollama
models. Throwaway clone: `/tmp/omp-dogfood-2803758`. Outputs:
`/tmp/omp-dogfood-out/` (ephemeral — copied here as references).
Provider: `enabledProviders=["claude-plugins"]` in profile
`dogfood550` only.

| # | Row | Result | Evidence | Notes |
|---|-----|--------|----------|-------|
| 1 | Hooks (`hooks/hooks.json`) | N/A plugin-side / FAIL host-side | No `hooks/` dir ships in the plugin; hook log `/tmp/omp-dogfood-out/hook-events.log` stayed 0 bytes across 3 omp `-p` session ends | omp (print mode) did not execute Claude-style project hooks. PreToolUse untested with a real tool call (see B1). |
| 2 | `/orchestrate` toy ticket (scope-confirm, plan-approve, ship-choice) | FAIL — DNF at skill invocation | `/tmp/omp-dogfood-out/row2-orchestrate.txt` | Model emitted hallucinated `<call>` blocks and a fake `xd://orchestrate` URI; nothing executed; no gate reached. Halt-vs-plow question unverified. |
| 3 | `/council` on one claim | FAIL — same invocation failure | `/tmp/omp-dogfood-out/row3-council.txt` | Fake `xd://council` read; no finder/judge spawn, no verdict. |
| 4 | `/review-and-commit` on 1-file diff | FAIL — no review, no commit | `/tmp/omp-dogfood-out/row4-review-commit.txt` | Fake bash line printed; repo unchanged. Nothing to revert. |
| 5 | `/memory search` + memory-store vs scratch DB | PASS (script level) / embeddings untested | `/tmp/omp-dogfood-out/toy-repo/.claude/memory/memory.db` | Schema init, write, LIKE-query, load-session all OK; parameterized `?` path held. Embeddings path not exercised. |
| 6 | `/ci-watch start` | DEGRADE expected / FAIL observed (invocation never happened) | `/tmp/omp-dogfood-out/row6-ciwatch.txt` | Fake JSON tool call printed; no cron created. Documented fallback is session-only. |

### Blockers

- **B1 — omp tool-calling dead in print mode** (root cause for rows 2–4, 6).
  Zero `tool_call` events in `--mode json` streams; input tokens constant at
  2051 across runs (no tool schemas attached). Hypothesis: the
  `openai-responses` API shim against ollama drops or never attaches tools.
- **B2 — spark-tf / vault-llama unusable.** No active credential; no models.
  Fell back to local ollama (qwen3.5-9b, devstral-24b).
- **B3 — gpt-oss-20b backend 500s.** Server-side chat-template bug
  (`index $prop.Type 0`); abandoned that model.
- **Model quality (separate from host gaps).** qwen3.5-9b fabricated
  tool-call syntax and ignored skill contracts; devstral-24b denied having
  tools. Neither is fit for gate-compliance testing even if B1 is fixed.
- **What worked:** smoke test; skill/agent discovery; `--profile` isolation;
  bounded runs; no writes to the main repo or host config.

### Follow-ups

1. Fix/verify omp tool attachment in `-p` mode for OpenAI-compatible
   providers (B1). Blocks all agentic rows.
2. Provision spark-tf/vault-llama credentials (B2).
3. Decide hook shipping strategy: bundle `hooks/hooks.json` or keep
   transcript-mirror opt-in and document the omp print-mode limit.
4. Re-run gate rows (orchestrate gates, council, review-and-commit) with a
   tool-capable model once B1 and B2 are fixed.
5. File the gpt-oss chat-template 500 (B3) as an infra ticket.
