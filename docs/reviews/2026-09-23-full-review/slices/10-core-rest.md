# Slice 10 — core-rest review (dev-team plugin @ v1.18.14, HEAD 60777e7)

## Slice summary

- **Overall grade: C+.** The mechanical layer is healthy: every in-slice test passes (smoke 139/0, smoke bite-test 35/0, plugin-dir-test 189/0, worktree-lib-test 60/0, install-test 17/0), `bash -n` is clean on every script, shellcheck `-S warning` reports only 4 unused-variable warnings, both manifests are valid JSON with descriptions in sync, CHANGELOG ordering is strictly descending (364 versions, no duplicates, top = plugin.json 1.18.14), and the models in AGENTS.md match the frontmatter of all 12 agents and the SPEC-003 tier table. The grade comes down because of the LLM-executed paths, and one of those breaks core onboarding.
- **P0: `/setup team` SQLite bootstrap is broken as written.** Steps 2, 2.5, 3 and 4 set `PLUGIN_DIR="$PDH"` (the plugin root) and then run `$PLUGIN_DIR/schema.sql`, `migrate.sh`, `download-extensions.sh` and `migrate-md.sh`. None of those files exists at the root; they live in `skills/memory-store/`. Steps 2.5 and 4 also assign `MEMDB` before `MROOT` inside a fresh shell. Reproduced.
- **P1 (security): `plugin-dir.sh` resolves from the cwd repo before the plugin.** With no `CLAUDE_PLUGIN_ROOT` set (the normal case in the Bash tool), any consumer repo that contains `skills/<relpath>` shadows the plugin's script. Example: a repo's own `skills/worktree-lib.sh` gets executed by `/status worktree`. Reproduced.
- **Systemic "MEMDB before MROOT" fence-order bug.** About 11 fences repo-wide assign `MEMDB="$MROOT/…"` before `MROOT` is resolved, so SQLite memory is silently skipped. In this slice: `commands/setup.md:272,329` and `skills/brainstorm/SKILL.md:64,83`. The same bug also appears in `AGENTS.md:152-160`.
- **CI covers only 6 of 77 test scripts.** 71 scripts run in neither CI nor `/release`, including in-slice `install-test.sh`, `skills/worktree-lib-test.sh` and `tools/smoke/test.sh`. When I ran all 77, 9 failed on master: about 5 from real drift, 2 from environment effects (running as root, missing generated hook), and 1 flaky in-slice test.
- **Doc drift clusters:**
  - Permission posture: the docs say `dontAsk` / Cell C, but the shipped default is `auto` / Cell D.
  - The `/focus` and `/blunt` "deprecation stubs" are still described, although they were deleted in v1.1.0.
  - The `install.sh` tier map contradicts the roster.
  - `SECURITY.md` lists 1.1.x as the current supported version; the plugin is at 1.18.x.
  - `docs/commands/refactor.md` predates the Escalation gate and worktree isolation.
- **Test gap in the latest release.** v1.18.14 added a new PDH stanza branch (the literal `${CLAUDE_PLUGIN_ROOT}` token) at 210 sites with no new assertion in `plugin-dir-test.sh` (still 189). That contradicts the repo's own CDT-237 lesson.
- **Token cost.** The PDH stanza (about 745 B) is repeated up to 9 times in one command (`commands/setup.md`). `skills/refactor/SKILL.md` is about 50 KB, and each behavioral agent carries about 130 lines of identical boilerplate (by design, drift-gated by sync-includes).

## Per-file review

| File | Lines | Purpose (short) | Verdict | Findings (concise, with line numbers) |
|---|---|---|---|---|
| .claude-plugin/marketplace.json | 26 | Marketplace: stable + edge channels | OK | Valid JSON. Both descriptions equal plugin.json. No per-plugin version, as intended (AGENTS.md:27). |
| .claude-plugin/plugin.json | 25 | Plugin manifest | OK | Valid JSON. Version 1.18.14 matches the top CHANGELOG heading. |
| .github/workflows/smoke.yml | 72 | CI gates (9 jobs) | Issue | Runs only 6 test scripts (see check (d)). No `permissions:` block (default token scope). No `timeout-minutes`. `actions/checkout@v4` is not SHA-pinned. No macOS runner despite the BSD-portability claims. `tools/smoke/test.sh` (bite-test), `install-test.sh` and `worktree-lib-test.sh` are not wired. |
| .gitignore | 55 | Ignore process state | Minor | `.worktrees` appears twice (l.1, l.55). `.claude/memory/extensions/`, `models/` and `memory.db*` (l.39-43) are redundant under `.claude/memory/*` (l.12). |
| AGENTS.md | 294 | Contributor rules | Issue | l.150-160: the "Session start" snippet tests `[ -f "$MEMDB" ]` before `MROOT`/`MEMDB` are assigned, so `USE_DB` is always false. The snippet also omits `.timeout`/`type` and differs from `protocol.md`. l.195-196: the directives exclusion list names only project-init and distiller, but l.77-78 says all 5 internal agents have none. l.36: the pre-commit enforcement only works after a manual `core.hooksPath`. |
| CHANGELOG.md | 1474 | Release history | Minor | 364 `### vX.Y.Z` headings, strictly descending, no duplicates, top = 1.18.14 = plugin.json. Only non-bullet block is the v1.0.0 migration table (l.575-625, intentional). 280 KB with very long single-line bullets (2 lines >2000 chars), which is costly if `/release` or scout reads it. The v1.0.0 table (l.601, 615) says `skills/validate-memory` and `skills/init-orchestration` were deleted at v1.1; v1.1.0 (retained backends) supersedes this, but the table was never annotated. |
| CLAUDE.md | 1 | Points to AGENTS.md | OK | — |
| CONTEXT.md | 49 | Repo glossary | OK | Format matches the domain-glossary skill. Decisions are dated. |
| LICENSE | 21 | MIT | OK | — |
| README.md | 352 | Project overview | Minor | l.139: the Internal paragraph lists 3 internal agents; l.55 lists 5. l.268-275: the `extraKnownMarketplaces` key `dev-team` differs from marketplace name `cold-dark-void`, and there is no `enabledPlugins` example (unverified whether that blocks auto-enable). l.301-313: the opencode `agents.paths` / `commands.paths` keys are unverified against the opencode schema. The command index covers all 20 `commands/*.md` (check (b)). |
| SECURITY.md | 18 | Vuln policy | Issue | l.7-8: supported versions are "1.1.x Yes / 1.0.x fixes"; the current line is 1.18.x, so 1.2–1.18 read as unsupported. |
| agents/devops.md | 227 | DevOps agent | OK | Model and effort match AGENTS.md and SPEC-003. Include region is identical to the other 6. See the shared agent findings (glossary never loaded, no "final-message not SendMessage" rule). |
| agents/ds.md | 223 | Data-science agent | OK | Same as devops. |
| agents/ic4.md | 226 | Well-defined IC | Minor | l.55 "Commit after each GREEN phase" may conflict with orchestrated review-before-commit flows (unverified). Shared agent findings apply. |
| agents/ic5.md | 243 | Complex IC | Minor | `effort: xhigh` on `model: sonnet`; host support for xhigh on Sonnet is unverified. l.71 has the same commit-per-GREEN note. |
| agents/pm.md | 191 | Product manager | Minor | l.60 "request escalation to an Opus-tier model", but pm already runs on Opus, so the instruction contradicts itself. |
| agents/qa.md | 249 | QA / release gate | OK | Shared agent findings apply. |
| agents/tech-lead.md | 245 | Tech lead | OK | Task-routing table is consistent with CHANGELOG v1.18.10. |
| commands/craft-loop.md | 61 | Loop-program architect entry | OK | Mode routing is clear. Hard rule is restated. |
| commands/mode.md | 178 | focus/blunt hub | Minor | l.177 "Legacy `/focus` and `/blunt` are deprecation stubs"; they were deleted at v1.1.0. l.55/88 "Read and follow `skills/focus/SKILL.md`" is a cwd-relative path that does not exist in a consumer repo (should be the Skill tool `dev-team:focus`). |
| commands/setup.md | 545 | Onboarding dispatcher | **Major** | **P0:** l.246, 270, 297, 327 set `PLUGIN_DIR="$PDH"` (root), then l.254/277/307/334 use `$PLUGIN_DIR/schema.sql`, `migrate.sh`, `download-extensions.sh` and `migrate-md.sh`, none of which exists at the root, so DB init, migration and extension download all fail. l.271-275 and l.328-332 set `MEMDB` before `MROOT`, which yields `/.claude/memory/memory.db`. l.37/127/142/434-450 still say `dontAsk` (shipped: `auto`). l.187/541 use `"$@"` in Bash-tool fences, which is always empty. The PDH stanza is repeated 9 times. |
| commands/status.md | 197 | Read-only status hub | Minor | l.132 `bash "$ROLLUP_SH" "$@"`: `$@` is empty in a Bash-tool fence, so the flags rely on the LLM rewriting the line. l.74 cwd-relative skill path, same as mode.md. |
| commands/tdd-gate.md | 277 | Toggle TDD PreToolUse hook | Issue | l.78-82: MROOT/WTROOT lines are placed before the `#!/usr/bin/env bash` of the hook template, so the file is written with a non-leading shebang, and the fence is both an "executable" fence and a file template (it would block on `cat` stdin if run). l.26 says "exits with code 2 (block)", which contradicts the graduated hint→warn→block. l.228-238: the hook entry has no `matcher`, so python3 spawns on every tool call. The Notes (l.274-277) claim dedup by `matcher`. The "Always allowed" table (l.40-47) omits `*.sh`/Makefile, which the code allows (l.111). |
| commands/worktree.md | 105 | Release a worktree | Minor | l.87 `"$slug"` is never assigned in the fence (LLM substitution). The confirm text (l.75-76) says "removes … feat/<slug> branch if clean", but the branch is `-D`-deleted regardless of merge state (see worktree-lib.sh). |
| docs/README.md | 108 | Docs hub | Minor | l.24 "`dontAsk` ship default"; shipped is `auto` (Cell D). |
| docs/commands/brainstorm.md | 102 | /brainstorm page | Minor | l.71/94 "All four rounds run", but Round 4 is conditional (skill l.134 "if the problem is still ambiguous"). |
| docs/commands/craft-loop.md | 71 | /craft-loop page | OK | — |
| docs/commands/mode.md | 72 | /mode page | Minor | l.14-15 "removed at v1.0.0"; README and the migrate runbook say v1.1.0. l.72 still labels them "Legacy stubs". |
| docs/commands/refactor.md | 71 | /refactor page | Issue | Omits the mandatory Escalation gate (2.2a), worktree isolation and the `--worktree` inline flag. The sample checklist (l.59-64) lacks the 3 new items the skill requires (skill l.599-601). |
| docs/commands/setup.md | 79 | /setup page | Minor | l.9 `dontAsk` (stale). l.61 "`--refresh` Re-probe / re-seed cortex" contradicts commands/setup.md l.488 (`--refresh` skips project-init). l.69 "8 mappable agents"; `write-model.sh` maps 10. |
| docs/commands/status.md | 63 | /status page | OK | — |
| docs/commands/worktree.md | 33 | /worktree page | OK | — |
| docs/runbooks/idea-to-plan.md | 158 | Brainstorm → plan runbook | Minor | l.94 example `SPEC-031-realtime-collab` collides with the real SPEC-031 (escalation gate), which can confuse agents that grep specs. |
| docs/runbooks/manual.md | 329 | Manual workflow | Issue | l.243 broken anchor `../setup.md#memory-configuration-memory-config` (real slug `memory-configuration--memory-config`). l.42/266 use cwd-relative `bash skills/worktree-lib.sh`, which AGENTS.md l.87 explicitly forbids and which is absent on a real install. l.22/215 `git checkout main` (repo default may be master). |
| docs/runbooks/migrate-to-v1.md | 165 | 0.x→1.0 checklist | Minor | l.65-66 `cp -a memory.db` without `-wal`/`-shm` can yield an inconsistent backup; prefer `sqlite3 .backup`. |
| docs/runbooks/onboarding.md | 167 | Day-one runbook | Minor | Skips `/setup project`, which README Quick Start runs first. l.35 "Safe to re-run anytime" but a re-run does not reseed cortex. |
| docs/runbooks/permission-posture-matrix.md | 360 | Posture evidence | OK | Consistent with Cell D. The `/tmp` paths are historical records. The pinned CC 2.1.190 is older than the 2.1.236 cited in CHANGELOG v1.18.14, so doctor `matrix.cc_version` will WARN (expected). |
| docs/setup.md | 245 | Setup guide | Minor | l.78 "Migrates existing v1 DBs to v2 schema" (schema is v4). l.85 "Safe to re-run — updates cortex for all agents" contradicts `--refresh`/Step 6. l.5 mentions legacy `/init-team`. No `/setup models` section. |
| githooks/pre-commit | 18 | Master bump-class hook | OK | Detached HEAD → exits 0 (acceptable). Opt-in via `core.hooksPath`. |
| install-test.sh | 140 | install.sh harness | Minor | Uses `sha256sum` (l.21, l.36), which fails on stock macOS. Not in CI. No uninstall test, no `--assign-models` apply test, no check of the stripped-agent contents. |
| install.sh | 259 | opencode installer | Issue | l.123-196: the tier map (haiku→ic4,qa; sonnet→devops,pm; opus→tech-lead,ic5,ds) contradicts the roster (ic4/qa/ic5 are Sonnet, pm is Opus). l.240: the `grep -v '^\s*(tools\|model):'` strip also removes body lines starting with `tools:`/`model:` (none today), and `\s` in ERE is non-portable (unverified on BSD). l.88-95: the default run silently deletes the user's `.agent.{ic4,…}` pins even without `--assign-models`. l.231-234: the comment lists 3 internal agents (5 exist). The `effort:` key is left in opencode copies (unverified acceptance). |
| skills/blunt/SKILL.md | 137 | Blunt tone mode | Minor | l.6/13 "/blunt is a deprecation stub" (deleted v1.1). No `user-invocable: false`, so it still surfaces as a slash skill. Profanity in the description (l.5) appears in the skill list. |
| skills/brainstorm/SKILL.md | 352 | Socratic refinement | Issue | l.63-67 and l.82-86: `MEMDB` is assigned before `MROOT` in a fresh shell, so SQLite cortex is never loaded (falls back to .md). The SQL lacks `-cmd ".timeout 5000"`. l.337 "NEVER skip default rounds" conflicts with Round 4's conditional (l.134). |
| skills/code-simplify/SKILL.md | 132 | Post-review polish | Minor | l.43-44 "revert the simplify edits" has no mechanism (no pre-simplify commit/stash step). |
| skills/craft-loop/SKILL.md | 185 | Loop-architect protocol | OK | l.80 refers to "six slots" while 5 are listed. |
| skills/craft-loop/examples/backlog-burn.md | 69 | Example program | Minor | l.31 commits after marking `.claude/backlog.md` [DONE]; AGENTS.md forbids staging `.claude/backlog*` into commits in consumer repos where it is not ignored. |
| skills/craft-loop/examples/spec-sync.md | 68 | Example program | OK | — |
| skills/craft-loop/program-template.md | 73 | Program skeleton | OK | Correct 4-backtick outer fence. |
| skills/domain-glossary/SKILL.md | 123 | CONTEXT.md protocol | Minor | Load protocol (l.73-83) reads `$MROOT/CONTEXT.md` (main checkout), but write-back targets `$WT_PATH/CONTEXT.md`, so inside a worktree freshly committed terms are not what gets loaded. l.104 table row has 2 cells vs a 3-column header. |
| skills/focus/SKILL.md | 225 | Focus mode | Minor | l.7/13 "/focus is a deprecation stub" (deleted v1.1). |
| skills/plugin-dir-test.sh | 1177 | plugin-dir + stanza tests | Minor | 189/189 pass. No assertion covers the v1.18.14 literal-`${CLAUDE_PLUGIN_ROOT}` stanza branch (`grep _pr=` → 0 hits). No negative test for consumer-repo shadowing (see P1). |
| skills/plugin-dir.sh | 442 | Install-aware resolver | Issue | **P1:** tiers 1-2 (l.178-192) resolve `$WTROOT/$rel` / `$MROOT/$rel` in the caller's repo before the plugin, with no plugin-identity check (compare the marketplace tier, which requires `agents/pm.md`), so a consumer repo hijacks it. l.14 comment "Dead in Bash-tool fences" is now half-stale after v1.18.14. `sort -V` is GNU-leaning (unverified on older macOS). |
| skills/refactor/SKILL.md | 700 | Design-first refactor | Issue | l.206/228: `[[ "$SAFE_PATH" != "$WTROOT"* ]]` clears every relative path, so `git log -- ""` fails ("empty string is not a valid pathspec"), reproduced. About 50 KB of prompt, heavy restatement of the arm/disarm rationale (l.335, 354-372, 421, 617, 641). |
| skills/scaffold-project/SKILL.md | 787 | /setup project backend | Issue | l.159 says orchestration is "`dontAsk` … Cell C" (stale). l.159 also claims "destructive commands like `rm` … will prompt", but the allowlist includes `python3:*`, `node:*`, `make:*`, `mv:*`, `cp:*` and `curl:*` (and `if :*`/`for :*`/`{:*`), so arbitrary deletion or exfiltration is possible without a prompt. l.629 template `.gitignore` = `.claude/` swallows `.claude/memory/seed/` (SPEC-024 committable seed) and the created `.claude/CLAUDE.md`. l.444/552: inner ``` fences close the outer ```markdown template early. l.737 references `~/.claude/CLAUDE.md`, which is never created. |
| skills/standup/SKILL.md | 269 | /status standup backend | Minor | l.93 `--author="<agent-name>"` never matches (agents do not author commits), so every task reads as "no commits → STALE". l.224 uses `EPIC_LIB="$PDH/…"` without `plugin-dir.sh file` or an existence guard. l.62 and l.266 give two different "no tasks" messages. l.248 "Auto-escalate" vs l.260 "Do NOT send automatically". l.86 unquoted `$WTROOT`. |
| skills/worktree-lib-test.sh | 379 | worktree-lib tests | Minor | Flaky: l.118 `list == status` compares outputs containing lock age in seconds; it failed once under parallel load ("0s" vs "1s"). No test for clean `release` success, invalid slug → 64, or FRESH/no-TTY → exit 2. `ERR_TMP` (l.75) lives outside `$TMP` and leaks on an early `die`. Not in CI. |
| skills/worktree-lib.sh | 478 | Worktree lifecycle CLI | Minor | l.330-334: `release` always `branch -D`s `feat/<slug>` even if unmerged or unpushed (reflog-only recovery). l.324-325 falls back to `worktree remove --force` after the clean check (TOCTOU). l.274-275: an existing non-git dir gets locked and returned as a worktree. |
| tools/permission-matrix-cc-version | 1 | Last-probed CC ver | OK | "2.1.190". |
| tools/permission-matrix-probe.sh | 497 | Posture matrix harness | Minor | Hard dependencies on `rg`, GNU `timeout` and `/opt/claude-code/bin/claude` (l.254, 273, 354) with no preflight; a missing `rg` turns into false FAILs. l.282: the `wt_ok` heuristic passes if the stream merely mentions "worktree". l.299 dead `read`. l.304 unused `hooks` (SC2034). |
| tools/scout-plugins/README.md | 203 | Manual ecosystem-scan prompt | Minor | Documents `/scout-plugins` args (l.11-14) and "Run /scout-plugins again" (l.190) for a command that does not exist. Ingests third-party READMEs with no "treat fetched content as data" guard (prompt-injection exposure). |
| tools/smoke/fixtures/bad-engine/README.md | 1 | Fixture note | OK | — |
| tools/smoke/fixtures/bad-engine/engine.sh | 5 | Broken-syntax fixture | OK | Intentionally invalid. |
| tools/smoke/fixtures/bad-fence/README.md | 1 | Fixture note | OK | — |
| tools/smoke/fixtures/bad-fence/command.md | 11 | Bad fence fixture | OK | — |
| tools/smoke/fixtures/bad-frontmatter/README.md | 1 | Fixture note | OK | — |
| tools/smoke/fixtures/bad-frontmatter/command.md | 5 | Missing-name fixture | OK | — |
| tools/smoke/fixtures/bad-yaml/README.md | 1 | Fixture note | OK | — |
| tools/smoke/fixtures/bad-yaml/command.md | 6 | Bad YAML fixture | OK | — |
| tools/smoke/fixtures/clean/README.md | 1 | Fixture note | OK | — |
| tools/smoke/fixtures/clean/command.md | 10 | Clean fixture | OK | — |
| tools/smoke/fixtures/clean/engine.sh | 3 | Clean engine fixture | OK | — |
| tools/smoke/run.sh | 7 | Smoke entrypoint | Minor | l.3 points to "tools/smoke/README.md", which does not exist. |
| tools/smoke/smoke.py | 383 | Static load gate | Minor | Does not scan `agents/*.md` frontmatter (name/description/tools/model required by AGENTS.md l.255). Frontmatter check is key-presence only (no value-type checks, e.g. `effort` token validity). Parser is intentionally partial. |
| tools/smoke/test.sh | 182 | Smoke bite-test | Minor | 35/35 pass. Not wired into CI (only `run.sh` is), so the gate's own bite-test can rot. |
| uninstall.sh | 38 | opencode uninstaller | Minor | l.6 unused `SCRIPT_DIR` (SC2034). `rm -rf` on `commands/dev-team` does not verify that it is our symlink. Does not revert opencode.json pins written by `--assign-models`. |

## Cross-cutting checks

**(a) plugin.json / marketplace.json.** Both parse as valid JSON. The two marketplace descriptions are byte-equal to plugin.json's description. marketplace.json has no `version` fields, which matches AGENTS.md l.27 and README l.341. JSON validity has no dedicated CI step; the docs-drift `manifest-desc` check exercises the manifests (docs-drift passes, rc 0).

**(b) README command/skill index vs reality.** All 20 `commands/*.md` appear in the README tables. The README also lists 9 skill-backed Surfaces (`/kickoff`, `/orchestrate`, `/release`, `/backlog`, `/brainstorm`, `/ci-watch`, `/review-and-commit`, `/refactor`, `/wrap-ticket`), and all of them exist in `skills/`. Gaps:
- **No skill sets `user-invocable: false`**, so every internal skill still appears in the slash menu (`/dev-team:<name>`). That includes skills that call themselves internal (scaffold-project, standup, domain-glossary, fix-ticket, init-orchestration, model-map, security-scan) and skills that are silent about it (autopilot, code-simplify, memory-compress, memory-recall, memory-store, spec-tooling, transcript-mirror, transcript-parse, retro-gate, retro-subagent, skill-lint, docs-drift, agent-memory, metrics, doctor-skill). As a result, `/focus` and `/blunt` are "deleted" per the README but still reachable as skills.
- `docs/commands/transcript-mirror.md` is linked from docs/README only, not from the README index. That is correct, since it is not a slash Surface.
- Docs that reference Surfaces that do not exist:
  - `/scout-plugins` (tools/scout-plugins/README.md).
  - The `/focus` and `/blunt` stubs (commands/mode.md:177, skills/blunt:6,13, skills/focus:7,13, docs/commands/mode.md:14-15,72).
  - `/memory-distill`, in the memory-compress description (out of slice).

**(c) AGENTS.md claims vs reality.**
- The roster models match frontmatter for all 12 agents and match the SPEC-003 tier table, including effort. ✓
- The "Persistent Memory Protocol" snippet at l.150-160 is broken: `MEMDB` is used before it is set.
- The directives exclusion list is incomplete (l.196).
- "Enforced by TaskCompleted hook" (l.265) refers to a locally generated hook, not a repo gate.
- The Worktree Protocol forbids cwd-relative `bash skills/worktree-lib.sh`, but docs/runbooks/manual.md:42,266 still uses it.
- The `/tmp` rule (l.268) is honored in-slice. The only hardcoded `/tmp` paths are historical records in permission-posture-matrix.md.

**(d) Test scripts not wired into CI.** `git ls-files` finds 77 test scripts. CI (smoke.yml) runs 6 of them:
- `retro-gate/test.sh`
- `release/test-bump-class.sh`
- `memory-store/test-seed-pack.sh`
- `wrap-ticket/prune-remote-test.sh`
- `plugin-dir-test.sh`
- `agent-memory/sync-includes-test.sh`

CI also runs the non-test gates `smoke/run.sh`, `check-skill-bash.sh`, `check-docs-drift.sh`, `check-bump-class.sh` and `sync-includes.py check`. `/release` adds nothing beyond `plugin-dir-test.sh`. That leaves 71 unwired, including in-slice `install-test.sh`, `skills/worktree-lib-test.sh` and `tools/smoke/test.sh`.

I ran all 77 (`HOME` sandboxed, `-P 8`): 68 passed and 9 failed.
- Real drift:
  - `handoff/detached-stub-test.sh`: commands/handoff.md is 12096 B, over the 12000 cap.
  - `orchestrate/router-static-test.sh`: T10 02-scope.md.
  - `retro-gate/scheduled-retro-test.sh`: "Filter 2 missing".
  - `release-train/test-integration.sh`.
  - `transcript-mirror/test.sh`: M4 append-fail.
  - `council/test-workflow-static.sh`: rc 1, cause not isolated.
- Environment:
  - `metrics/test.sh`: the root user can write the "unwritable" path.
  - `retro-gate/friction-capture-test.sh`: needs the generated hook.
- In-slice flake: `worktree-lib-test.sh` (list==status age race).

Everything unwired is rotting on master; the out-of-slice failures are for other slice owners to confirm.

**(e) install.sh / uninstall.sh.**
- Safety is reasonable:
  - `set -euo pipefail`.
  - Paths come from constant suffixes, and `HOME` unset aborts before any `rm`.
  - `--dry-run` gating is complete and tested.
  - No TTY prompts in dry-run or non-TTY.
  - jq edits go through a tmp file and `mv`.
- Correctness issues: the stale tier map (P2), the default run silently dropping user pins for 7 agent names, the strip regex matching body lines, and uninstall neither verifying symlink ownership nor reverting pins.
- Portability: `install-test.sh` needs GNU `sha256sum`. I did not run either script against the real home directory.

**(f) Behavioral agents consistency.**
- The 7 agents share the tools list (Read, Write, Edit, Bash, Grep, Glob, Task*, SendMessage), and only the order varies: pm, qa and tech-lead list Grep/Glob before Bash.
- All have `mode: subagent`, the same Output-intensity block, and a byte-identical `protocol.md` include apart from the agent name (sync-includes check passes).
- Model and effort match AGENTS.md and SPEC-003.
- Issues:
  - None of the 7 loads `CONTEXT.md`, even though AGENTS.md l.243-249 says design-naming work must.
  - None carries the "no addressable parent; return as final message" rule (AGENTS.md l.218) while holding SendMessage. Consumer projects never see this repo's AGENTS.md, so the rule has to live in the agent files.
  - The memory write snippet uses an unset `$CONTENT` variable in the SQLite branch but a `<content>` heredoc placeholder in the .md branch, which is inconsistent.
  - The embed resolver skips the marketplace tier and the literal-token tier that PDH now uses.
  - pm.md escalates to "Opus-tier" while already Opus.
  - Boilerplate is about 130 lines × 7 (a deliberate trade-off).

## Findings

1. **P0 — `/setup team` cannot initialize SQLite memory.** `commands/setup.md:246,270,297,327` set `PLUGIN_DIR="$PDH"` (plugin root), then l.254 `sqlite3 … < "$PLUGIN_DIR/schema.sql"`, l.277 `migrate.sh`, l.307 `download-extensions.sh` and l.334 `migrate-md.sh`.
   - Evidence: `ls $PDH/{schema.sql,migrate.sh,download-extensions.sh,migrate-md.sh}` fails for all 4 files; they exist only under `skills/memory-store/`. Step 1 (l.231) correctly uses `plugin-dir.sh dir skills/memory-store/schema.sql`, but each later fence is a fresh shell that overrides it.
   - Fix: in each fence use `PLUGIN_DIR=$(bash "$PDH/skills/plugin-dir.sh" dir skills/memory-store/schema.sql)`. Add a smoke or bite test that extracts these fences and asserts the referenced files exist.
2. **P1 — `plugin-dir.sh` lets the consumer repo shadow plugin scripts (code-execution hijack).** `skills/plugin-dir.sh:178-192`.
   - Evidence: in a temp repo containing `skills/worktree-lib.sh` (`echo PWNED`), `env -u CLAUDE_PLUGIN_ROOT bash plugin-dir.sh file skills/worktree-lib.sh` prints the repo's file. Every `/status worktree`, `/worktree release`, `/setup` and doctor call executes it.
   - Fix: gate tiers 1-2 on plugin identity (for example `.claude-plugin/plugin.json` with `"name": "dev-team"` plus `skills/plugin-dir.sh` at that root, mirroring the marketplace `agents/pm.md` check), or add a self-location tier (`$(dirname "${BASH_SOURCE[0]}")/..`) ahead of the cwd tiers. Add a negative test.
3. **P1 — "MEMDB before MROOT" fence ordering silently disables SQLite reads.** In slice: `commands/setup.md:271-275, 328-332` and `skills/brainstorm/SKILL.md:63-67, 82-86`. Repo-wide: kickoff:120-122 and 139-141, and memory-recall:203, orchestrate/steps/00-resolve.md:66 and wrap-ticket:196/230 (same pattern, unverified in detail). Also `AGENTS.md:152-160`.
   - Evidence: a fresh-shell repro prints `MEMDB=/.claude/memory/memory.db`, so setup migration is skipped and brainstorm/kickoff always use the .md fallback.
   - Fix: move the `_gc`/`MROOT` lines first. Add a skill-lint rule: any fence that references `$MROOT` must assign it earlier in the same fence.
4. **P2 — 71 of 77 test scripts are not in CI or `/release`, and about 5 already fail on master.** See check (d).
   - Fix: add a CI job that runs every `*test*.sh` under `skills/` and `tools/`, plus `install-test.sh`, with a quarantine allowlist, and fix or annotate the current reds. Add `permissions: contents: read` and `timeout-minutes`. Consider a macOS job for the portability claims.
5. **P2 — v1.18.14's new stanza branch is untested.**
   - Evidence: `grep -c "_pr=" skills/plugin-dir-test.sh` → 0. The CHANGELOG says 210 emissions changed, and PASS stayed at 189.
   - Fix: add positive/negative assertions for the literal `${CLAUDE_PLUGIN_ROOT}` branch (substituted vs unsubstituted), including precedence relative to the cwd tier.
6. **P2 — Permission-posture docs contradict the shipped default (`auto` / Cell D).** `commands/setup.md:37,127,142,434-450`, `docs/commands/setup.md:9`, `docs/README.md:24`, `skills/scaffold-project/SKILL.md:159` ("under `dontAsk` … Cell C").
   - Evidence: `skills/init-orchestration/SKILL.md:467` sets `"defaultMode": "auto"`.
   - Fix: replace the text with "auto (Cell D)"; docs-drift could grep for `dontAsk` outside historical sections.
7. **P2 — `install.sh` opencode tier picker maps agents to the wrong tiers.** `install.sh:123-196` (ic4/qa→"Haiku", pm→"Sonnet", ic5→"Opus").
   - Evidence: the AGENTS.md roster and frontmatter say ic4, qa and ic5 are Sonnet and pm is Opus.
   - Fix: derive the map from each agent's `model:` frontmatter instead of hard-coding it; extend it to finder, debugger and council-judge, or document the exclusion.
8. **P2 — `scaffold-project` allowlist safety claim is misleading.** `skills/scaffold-project/SKILL.md:114-150,159`.
   - Evidence: `Bash(python3:*)`, `node:*`, `make:*`, `mv:*`, `cp:*`, `curl:*`, `if :*`, `for :*` and `{:*` are allowed, yet the text says `rm` "will prompt". Any of those runs arbitrary deletion or exfiltration unprompted. How CC matches compound commands such as `if …; then rm …` is unverified.
   - Fix: state the real boundary, and drop `curl:*` plus the compound prefixes or scope them.
9. **P2 — Scaffolded `.gitignore` ignores all of `.claude/`.** `skills/scaffold-project/SKILL.md:629`. This conflicts with the SPEC-024 committable `.claude/memory/seed/` carve-out and with setup.md l.348-349 ("Never write a bare `.claude/memory/` exclude").
   - Fix: emit child globs plus a `!.claude/memory/seed/**` negation, as this repo's own .gitignore does.
10. **P2 — Refactor Step 1b path guard discards every relative path.** `skills/refactor/SKILL.md:206,228`.
    - Evidence: repro gives `SAFE=[]`, then `fatal: empty string is not a valid pathspec`.
    - Fix: canonicalize first (`case "$SAFE_PATH" in /*) ;; *) SAFE_PATH="$WTROOT/$SAFE_PATH";; esac`), then prefix-check, and skip `git log` when the result is empty.
11. **P2 — `SECURITY.md` supported-versions table is stale.** `SECURITY.md:7-8` lists 1.1.x as current while the plugin is 1.18.14.
    - Fix: use "latest 1.x minor: yes; previous minor: security fixes", or let `/release` update the table.
12. **P2 — Internal skills are user-invocable.** None of the 41 `skills/*/SKILL.md` sets `user-invocable: false`, so scaffold-project, standup, fix-ticket, init-orchestration, focus, blunt and others show in the slash menu despite "Not a user entry". Claude Code support for that key is per the host docs (unverified for opencode).
    - Fix: add `user-invocable: false` to internal skills, and teach smoke/docs-drift the allowed set.
13. **P2 — `docs/commands/refactor.md` is outdated.** It lacks the mandatory Escalation gate, worktree isolation and the new checklist items (skill l.285-350, 599-601).
    - Fix: regenerate from the skill's Arguments and Rules sections.
14. **P2 — The domain glossary is never loaded by the 7 behavioral agents, and load/write paths disagree.** `agents/*.md` (no CONTEXT.md reference; only project-init has one); `skills/domain-glossary/SKILL.md:73-83` vs l.104.
    - Fix: add a 3-line glossary load to the agent Project Awareness sections (outside the managed include), and load `$WTROOT/CONTEXT.md` first, then `$MROOT`.
15. **P3 — `commands/tdd-gate.md` hook template is malformed.**
    - l.78-82: the path lines come before the shebang.
    - There is no `matcher`, so the hook runs on every tool.
    - l.26 contradicts the graduated enforcement.
    - Fix: mark the fence `bash template` (or emit it via a heredoc), put the shebang first, and add `"matcher": "Write|Edit|MultiEdit"`.
16. **P3 — Stale `/focus` and `/blunt` stub references.** `commands/mode.md:177`, `skills/blunt/SKILL.md:6,13`, `skills/focus/SKILL.md:7,13`, `docs/commands/mode.md:14-15,72` (which also says v1.0.0 instead of v1.1.0).
    - Fix: say the stubs were "deleted at v1.1.0".
17. **P3 — Broken anchor and forbidden invocation in `docs/runbooks/manual.md`.** l.243 anchor `memory-configuration-memory-config` should be `memory-configuration--memory-config`. l.42 and l.266 use cwd-relative `bash skills/worktree-lib.sh` (AGENTS.md l.87 forbids it).
    - Fix: correct the anchor; use `/worktree release <slug>` and the PDH resolution for `ensure`.
18. **P3 — `worktree-lib.sh release` force-deletes unmerged branches.** l.330-334 `branch -D` runs without checking merge or push state. `commands/worktree.md:75-76` says "if clean", which users will read as "safe".
    - Fix: warn (or require `--force-branch`) when `feat/<slug>` has commits not on any remote or base; at least print the tip SHA for reflog recovery.
19. **P3 — `worktree-lib-test.sh` is flaky.** l.118 `assert_eq "list == status"` compares outputs that include a live second-granularity age. It failed once in a parallel run.
    - Fix: re-run status immediately before list, or strip the age column.
20. **P3 — `docs/commands/setup.md` has two inaccuracies.** l.61 describes `--refresh` as reseeding cortex (it skips project-init), and l.69 says "8 mappable agents" (`write-model.sh:29` maps 10). `docs/setup.md:78` also cites schema v2 (the schema is v4).
    - Fix: correct the text.
21. **P3 — `pm.md` escalation instruction contradicts itself.** `agents/pm.md:60` escalates to "an Opus-tier model" while running on Opus.
    - Fix: "escalate to the orchestrator/user with the specific blocker".
22. **P3 — `tools/smoke/run.sh:3` points to a missing README.**
    - Fix: point to `specs/core/SPEC-030-smoke-harness-gate.md`.
23. **P3 — `tools/scout-plugins/README.md` has an orphan command reference and no untrusted-content guard.** It mentions `/scout-plugins` (l.11-14, 190) and ingests web pages with no instruction to treat them as data.
    - Fix: rename the usage to "manual prompt" and add an explicit untrusted-content rule.
24. **P3 — `standup` staleness heuristic always fires.** `skills/standup/SKILL.md:93` greps `--author="<agent-name>"`, which never matches, so every in-progress task is flagged STALE.
    - Fix: use `--grep` on the ticket id or trailer, or drop the commit indicator.
25. **P3 — `install-test.sh` is not portable.** `sha256sum` (l.21, 36) is missing on stock macOS.
    - Fix: use `sha256sum || shasum -a 256`.
26. **P3 (unverified) — `effort: xhigh` on a Sonnet agent** (`agents/ic5.md:6`) may not be supported by the host.
    - Fix: confirm the host's effort matrix; SPEC-003 already records this as intentional.

## Enhancement proposals

| # | Proposal | Effort | Impact |
|---|---|---|---|
| E1 | "Fence doctor" lint: in each ```bash fence, require assignment-before-use for `MROOT`/`WTROOT`/`MEMDB`/`PLUGIN_DIR`, and resolve any `$PLUGIN_DIR/<file>` or `$PDH/<file>` literal against the repo tree. Catches findings 1, 3 and 10 mechanically. | M | High |
| E2 | One CI job that discovers and runs every `*test*.sh` (quarantine list for known-env failures), plus `permissions: contents: read`, `timeout-minutes`, and a matrix entry on `macos-latest` for the smoke, plugin-dir, worktree-lib and install tests. | S | High |
| E3 | Give `plugin-dir.sh` a self-location tier and a plugin-identity check for the cwd tiers (fixes P1 and removes most need for the 745 B stanza inside plugin-shipped scripts). | S | High |
| E4 | Generate the `install.sh` opencode tier map from agent frontmatter (`model:`) so it can never drift from the roster again. | S | Med |
| E5 | Add `user-invocable: false` to internal skills and a docs-drift rule that the set of user-invocable skills equals the README index. | S | Med |
| E6 | A docs-drift "stale-term" list (`dontAsk` outside matrix history, "deprecation stub", "v2 schema", "8 mappable"), failing when these appear outside allowlisted historical files. | S | Med |
| E7 | Trim `skills/refactor/SKILL.md` (~50 KB): move the arm/disarm rationale into SPEC-031 and keep one-line pointers, for about 30-40% fewer tokens per `/refactor` run. | M | Med |
| E8 | Add a "Glossary + hand-back" non-managed block to the 7 agents (load CONTEXT.md; return results as the final message, never SendMessage to a non-existent parent). | S | Med |
| E9 | `/release` should update `SECURITY.md` supported versions and check the doc anchor links (the checker used for this review is a 20-line python script). | S | Low-Med |
| E10 | `worktree-lib.sh release --keep-branch` and an unmerged-commit warning; add clean-release, invalid-slug and no-TTY tests. | S | Med |

## Coverage attestation

- Files in the slice list: **75**. Rows in the Per-file table: **75**. The counts match.
- Every file was opened and read in full, with two partial exceptions:
  - `skills/plugin-dir-test.sh`: read by section headers and targeted greps, and executed (189/189).
  - `CHANGELOG.md`: checked structurally in full (every heading and non-bullet line, ordering, duplicates, version match), with content sampled across its whole length.
- Tests executed:
  - `bash tools/smoke/run.sh`: 139 checked, 0 failed.
  - `bash tools/smoke/test.sh`: 35/0.
  - `bash skills/plugin-dir-test.sh`: 189/0.
  - `bash skills/worktree-lib-test.sh`: 60/0 (1 flaky fail in a later parallel run).
  - `bash install-test.sh`: 17/0, with a sandboxed `HOME`.
  - `bash -n` on all slice scripts: OK.
  - shellcheck `-S warning`: 4 SC2034/SC2155 warnings only.
  - docs-drift: rc 0. skill-lint: rc 0.
  - All 77 repo test scripts: 68 pass, 9 fail.
- Read-only: no repo file was modified (`git status` clean).
