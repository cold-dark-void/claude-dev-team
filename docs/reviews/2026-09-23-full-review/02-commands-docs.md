## Slice: commands (small) + docs

I read every file in the slice in full: 16 commands, docs/README.md, docs/setup.md, 23 docs/commands pages and 10 runbooks. I checked references with ls and grep, ran `skills/skill-lint` on all 16 commands, and ran a link and anchor checker over docs/. Everything was read-only; I changed nothing.

**Two P0 bugs to fix first:**
1. **`/setup team` is broken if its bash blocks are run as written** (commands/setup.md).
   - Steps 2, 2.5, 3 and 4 set `PLUGIN_DIR="$PDH"` (lines 246, 270, 297, 327). That is the plugin root, but `schema.sql`, `migrate.sh`, `download-extensions.sh` and `migrate-md.sh` live under `skills/memory-store/`, so all four steps fail.
   - Steps 2.5 and 4 set `MEMDB="$MROOT/…"` before `MROOT` is computed (lines 272→273 and 329→330). In a fresh shell that gives `/.claude/memory/memory.db`, so the migration is silently skipped.
   - Step 5b sets `SETTINGS` and `HOSTS_TO_ADD` in one block (415-430) and uses them in the next (463-483). That runs `echo '{}' > ""` and adds nothing to the allowlist. The `# lint-ok: C1` waivers on lines 466 and 470 hide this.
2. **commands/epic.md:36 says the `--autopilot` token is "Unused by /epic… Independent of --worktree/--release".** This contradicts skills/epic/SKILL.md:209-212 and AGENTS.md ("seal-intent… Token is not unused"). An agent that trusts the command file will drop `release_bump`, which is the exact failure AGENTS.md warns about.

### Per-file review
| File | Purpose | Verdict | Findings |
|---|---|---|---|
| commands/adjust-agent.md | Directives CRUD + Model map sugar | minor | (1) `grep -c … \|\| echo 0` (L81) prints `0\n0` when the file exists with no numbered lines, which breaks the table. I confirmed this by running it. (2) Steps 4-6 use `$AGENT` that is never set in the shell, only waived with `lint-ok: C1` (L125/142/167/264), so the model has to substitute it. (3) finder and debugger can be mapped in `write-model.sh:29`, but L61/96 only mention council-judge. (4) The PDH stanza appears 4 times. (5) The step order is Dashboard=3, Read=4, Adjust=5, Apply=6, Model=7, but routing jumps to 7 first, which reads oddly. |
| commands/audit.md | Thin wrapper over audit.sh | minor | `bash "$AUDIT_SH" "$@"` (L57): `$@` is empty in a Bash-tool shell and it doesn't use `$ARGUMENTS`, so pass-through relies on the model rewriting it. The docs never explain how to get the `FILE` that `apply` needs (run `--json > FILE` first). Step 1 and Step 2 resolve the same PDH twice. |
| commands/bug-hunt.md | Host for bug-hunt skill | OK | Frontmatter, routing and refs all verified. Only nit: the "Shipped (CDT-…)" changelog prose at L50 doesn't belong in a command. |
| commands/compact-transcript.md | Wrapper for Meaning tail | minor | `"$@"` pass-through (L51), same as audit. Its reference to "discover-warm.sh line 1" is correct; I verified it in compact-transcript.py:27. |
| commands/craft-loop.md | Routes to craft-loop skill | minor | No `argument-hint` (usage is only inside the description). Otherwise clear. |
| commands/debug.md | Host for debug skill | minor | L61 cites a bare `SPEC-029` with no path. Otherwise OK. |
| commands/doctor.md | Wrapper for doctor.sh | minor | `"$@"` pass-through (L86). L27 lists only the `transcript` and `config` groups, but doctor.sh also has `version`, `memory`, `settings`, `hooks`, `worktree`, `deps` and `plugin` (L31's example uses `memory`). There is no docs page. |
| commands/epic.md | Entry for epic skill | **significant** | P0 #2 above (L36). `$EPIC_ID` and `$CHILD_ID` are never set in the dispatch block (L53-62). The `--redecompose` and `--no-context-discipline` routing lives only in prose. |
| commands/handoff.md | STM packet parent stub | **significant** | (1) Step 1 (parse) and Step 3 are separate blocks. Step 3 re-defaults `UUID="${UUID:-}"; WARM="${WARM:-0}"` (L98), so across Bash calls a bare `/handoff` turns into cold mode with an empty UUID and fails the UUID-shape check. (2) `set -- $ARGUMENTS` (L18) is unquoted, so it word-splits and globs. (3) The error file `E="${TMPDIR:-/tmp}/handoff.err"` (L102) has a fixed name and will collide between concurrent sessions; `mktemp` is better. (4) The spawn prompt asks for `SPINE=…` (L208), but the parent never prints SPINE. (5) Help and unknown flags exit 0, and the exit is in prose only, not in bash. (6) The UUID check (L106) accepts anything after the first 8 hex chars. (7) Step 2's prose is garbled ("light skills/handoff/LIGHT.md"). (8) The cache-hit and too-fresh messages differ from docs/commands/handoff.md L349 and L407-411. |
| commands/mode.md | focus/blunt dispatcher | minor | L177 says "Legacy /focus and /blunt are deprecation stubs", but docs/README:87 says the stubs were deleted in v1.1.0. The skills/focus and skills/blunt descriptions still say the same thing. Also, the sub-sections say "Read skills/focus/SKILL.md" with a relative path, not PDH-resolved, which fails on an installed plugin (the `Skill` tool works; a Read of a relative path does not). |
| commands/recall.md | Cross-source recall | **significant** | (1) `argument-hint: [topic]` (L6) is unquoted YAML and parses as a list; it's the only such hint in commands/. (2) No handling for an empty topic: bare `/recall` greps `""`, which matches everything. (3) `$ARGUMENTS` goes straight into shell (L41, 87-138), so quotes or `$()` in the topic break or inject. (4) `$MROOT` is unquoted (L87/103/116/129). (5) LIKE wildcards `%` and `_` are not escaped (L74). (6) SQL `LIMIT 10` (L77) vs the "5 memory matches" rule (L247). (7) `2>/dev/null` is on grep, not ls (L138). |
| commands/release-train.md | Entry for train skill | minor | `dry-run` claims "zero mutation" but Step 2 always runs `init` first (L30). The `register` example drops `--assumed` and silently defaults to `--bump minor` (L39). `status` is not a verb in train-lib; it maps to `list` (table L22 is ambiguous). No docs page. |
| commands/setup.md | Onboarding dispatcher | **significant (P0)** | P0 #1 above. Also: (4) `EXT_GITIGNORE_DONE` (L307) and `SEED_IMPORT_SUMMARY` (L407) are exported for later blocks and are lost across Bash calls. (5) The `--skip-doctor` scan uses `"$@"` (L187). (6) The `team` approval text (L447-453) asks the user to approve writing bash-compress.sh, which the team path never does; it was copied from orchestration. (7) The usage block (L37) and L142 say `dontAsk`, but the shipped posture is `auto` (Cell D; init-orchestration SKILL:27/467). (8) L81 cites the deleted `commands/init-team.md`. (9) `echo '{}' > "$SETTINGS"` has no `mkdir -p .claude`. (10) The PDH stanza appears 9 times. |
| commands/status.md | Read-only hub | minor | `"$@"` pass-through (L132). PDH appears 4 times. Refs verified (rollup `--section`, dag-lib, standup skill). |
| commands/tdd-gate.md | Toggle TDD PreToolUse hook | **significant** | (1) The hook body block starts with a `_gc=…MROOT/WTROOT` preamble *before* `#!/usr/bin/env bash` (L78-82), so the written script's shebang is not on line 1, and the preamble is dead code. (2) The file content sits in a ```` ```bash ```` fence that looks runnable; if the model runs it, `INPUT=$(cat)` hangs. (3) The settings JSON (L229-238) has no `matcher`, so python3 is spawned on every tool call, and Notes L275 says dedup is by `matcher`. (4) No `argument-hint`, and no handling for unknown args. (5) The description and L248 say "blocks", but hits 1 and 2 are allowed. (6) The allowed-list in the docs omits `*.sh`, `Makefile` and `Taskfile*`, which the script allows. (7) `chmod +x .claude/hooks/…` (L221) depends on the working directory. |
| commands/worktree.md | Release a worktree | **significant (UX/data-loss)** | The confirmation (L75-77) says "removes the worktree and feat/<slug> branch if clean", but the lib (worktree-lib.sh:324-333) runs `branch -D`, which deletes the branch even when it is unmerged or unpushed, and falls back to `worktree remove --force`. AGENTS.md says "Leave commits on feature branches". The prompt should show the unmerged/unpushed commit count before asking. |
| docs/README.md | Docs hub + command index | **significant** | (1) The Docs column says "skill" for `/doctor`, `/adjust-agent`, `/release-train` and `/tdd-gate`, but those are commands with no page (L41/63/69/74). (2) L24 says "`dontAsk` ship default"; it is now `auto` (the matrix doc itself says so). (3) handoff-stm-dogfood.md is missing from Guides. (4) No mention that skill entries are namespaced (`/dev-team:…`). |
| docs/setup.md | Setup guide | **significant** | L5 calls `/init-team` "legacy" (it is deleted). L78 says "Migrates v1→v2 schema" (now v4). L130-133 and the orchestration section list 2 approvals, but there are 3 (escalation-gate.sh, SPEC-031). The escalation-gate hook is missing from the orchestration list. L85 "Safe to re-run — updates cortex" conflicts with the `--refresh` semantics. |
| docs/commands/audit.md | /audit page | minor | Missing `-h`. L51 links `/doctor` to ../README.md (no page). No example of producing the JSON FILE for apply. |
| docs/commands/brainstorm.md | Skill page | minor | L94 "All four rounds run even if 'just build it'" contradicts L79 and the skill's "Round 4 (if still ambiguous)". |
| docs/commands/bug-hunt.md | /bug-hunt page | minor | Accurate (the `--severity-floor=` form is supported by the skill). About 330 lines that largely restate SPEC-034; it's bloated. |
| docs/commands/compact-transcript.md | Page | OK | Path and 32768 bound verified against compact-transcript.py. |
| docs/commands/council.md | Page | minor | Missing `--external[=codex\|gemini]`, `--council-tier=` and `--why`, which are in the command's argument-hint. |
| docs/commands/craft-loop.md | Page | OK | Consistent with the command. |
| docs/commands/debug.md | Page | minor | L10 says `/fix-ticket` was "removed at v1.0.0"; L104 says "deleted at v1.1.0". |
| docs/commands/epic.md | Page | **significant** | The usage and flags table omit `--autopilot[=token]` and `--no-context-discipline`, and the doc never states that the bump token implies seal intent (the P0 #2 area). |
| docs/commands/handoff.md | Page | minor | Output strings differ from the command (see handoff row). Otherwise thorough, but at 444 lines it is very long. |
| docs/commands/kickoff.md | Skill page | minor | The example spec `SPEC-007-csv-export` collides with a real SPEC-007 name. Otherwise OK. |
| docs/commands/memory.md | Page | minor | L5 says `/memory-*` were "removed at v1.0.0" (it was v1.1.0). The anchor `../setup.md#memory-configuration-memory-config` is broken (the real one is `…configuration--memory-config`). |
| docs/commands/mode.md | Page | minor | L15 says "removed at v1.0.0" while L72 says "Legacy stubs"; both conflict with the README's v1.1.0. |
| docs/commands/orchestrate.md | Skill page | minor | Step numbers repeat "12." (L67/68). Usage omits the flag forms. Flags verified. |
| docs/commands/recall.md | Page | minor | Same caps as the command, but it doesn't document empty-topic behavior. |
| docs/commands/refactor.md | Skill page | OK | No issues. |
| docs/commands/retro.md | Page | minor | L272 says "/kickoff (Step 9)", but the skill's step is 8b and the kickoff doc says step 10. |
| docs/commands/review-and-commit.md | Skill page | minor | The examples use `/tmp/review.md`; `${TMPDIR:-/tmp}` would be consistent with the house rule. Otherwise OK. |
| docs/commands/setup.md | Page | **significant** | L9 says `dontAsk` while L49 says Cell D `auto` (self-contradiction). The `--refresh` row says "re-seed cortex", but the command's Step 6 says `--refresh` does not rescan. `--skip-doctor` is missing from the team flags. L69 says "8 mappable agents"; write-model.sh maps 10. |
| docs/commands/spec.md | Page | minor | "Removed at v1.0.0". Claims a "9-section skeleton" but shows 5. Missing `reflect --phase N` and `--report` (skill L39). |
| docs/commands/status.md | Page | OK | Matches the command. |
| docs/commands/transcript-mirror.md | Opt-in recorder guide | **significant** | Every instruction is relative to the working directory (`skills/transcript-mirror/hook-shim.sh`, the cron line `cd <PROJECT> && bash skills/…`, L20/192-222/240). None of those paths exist in a user project on an installed plugin, which AGENTS.md forbids. It says "not a slash command", yet the skill has no `user-invocable: false`, so `/dev-team:transcript-mirror` is still exposed. Dev-log text is left in (L122 "no live SubagentStop this run"). |
| docs/commands/worktree.md | Page | minor | Doesn't warn that release force-deletes `feat/<slug>` (`-D`). |
| docs/commands/wrap-ticket.md | Skill page | minor | Step 9 says it uses `git worktree remove` without force. The skill actually calls `worktree-lib.sh release` (SKILL:437-440), which runs `branch -D` and has a `--force` fallback. The doc is stale. |
| docs/runbooks/handoff-stm-dogfood.md | Maintainer AC-16 gate | minor | Internal ship-gate process mixed into user docs. Uses `bash skills/…` relative to the working directory (L70, L137-141, L166). Not listed in the docs index. |
| docs/runbooks/idea-to-plan.md | Runbook | OK | Minor: the example spec `SPEC-031-realtime-collab` collides with a real SPEC-031. |
| docs/runbooks/manual.md | Manual flow | **significant** | `bash skills/worktree-lib.sh ensure/release` (L200 and L424 in my concatenated read) is the exact cwd-relative form AGENTS.md bans. `cat .claude/memory/*/cortex.md` only works in fallback mode. `echo "\n…" >>` writes a literal `\n`. `go test ./...` is project-specific. The anchor `#memory-configuration-memory-config` is broken. |
| docs/runbooks/memory.md | Memory runbook | minor | The troubleshooting advice "delete and re-bootstrap" destroys data; it should point to `/memory validate` or `/memory export` first. `/memory validate` is missing from the hygiene checklist. |
| docs/runbooks/migrate-to-v1.md | 0.x→1.0 checklist | minor | Correct PDH use. The CDT-68 approvals list 2 (now 3). |
| docs/runbooks/onboarding.md | Day-one | minor | No `/doctor` step and no `/setup project` step, yet it says "`/setup project` seeds CONTEXT.md". |
| docs/runbooks/orchestrate.md | Orchestrated runbook | minor | The example `/orchestrate POC-123 "…text…"` uses an inline-text form the skill doesn't document (SKILL L18-19). "Step 11" ship vs the doc's "12". Broken setup anchor. |
| docs/runbooks/permission-posture-matrix.md | Evidence record | minor | An evidence log, not a runbook. The artifact index lists local `/tmp/…` scratch dirs that don't exist. |
| docs/runbooks/scheduled-retro.md | Cron recipe | minor | Helpers use `bash skills/retro-gate/…` relative to the working directory (L135-139). "SlashCommand" tool naming may be stale. A literal `&lt;` appears in markdown (L110). |
| docs/runbooks/specs.md | Specs runbook | OK | Consistent with /spec. |

### Surface↔docs coverage matrix
| Surface | Kind | docs/commands page | docs/README row | Docs column |
|---|---|---|---|---|
| adjust-agent | command | **MISSING** | yes | wrongly "skill" |
| audit, bug-hunt, compact-transcript, council, craft-loop, debug, epic, handoff, memory, mode, recall, retro, setup, spec, status, worktree | command | yes | yes | OK |
| doctor | command | **MISSING** | yes | wrongly "skill" |
| release-train | command | **MISSING** | yes | wrongly "skill" |
| tdd-gate | command | **MISSING** | yes | wrongly "skill" |
| brainstorm, kickoff, orchestrate, refactor, review-and-commit, wrap-ticket | user skill | yes | yes | OK |
| backlog | user skill | **MISSING** | yes | "skill" |
| ci-watch | user skill | **MISSING** | yes | "skill" |
| release | user skill | **MISSING** | yes | "skill" |
| transcript-mirror | internal (has page) | yes | Guides only | OK |
| focus, blunt, and all other internal skills (fix-ticket, init-orchestration, scaffold-project, standup, domain-glossary, memory-*, metrics, model-map, retro-*, security-scan, skill-lint, spec-tooling, transcript-parse, validate-memory, autopilot, code-simplify, docs-drift) | internal | n/a | Internal note | **All lack `user-invocable: false`, so they still show up as `/dev-team:<name>`** |

Gaps: 7 surfaces have no page (adjust-agent, doctor, release-train, tdd-gate, backlog, ci-watch, release), and 4 README rows mislabel commands as skills.

### Cross-cutting findings
1. **Arguments are not reliably passed through.** Five commands pass args with `"$@"` (audit:57, compact-transcript:51, doctor:86, status:132, setup:187), which is empty in a Bash-tool shell. handoff and recall use `$ARGUMENTS`, but unquoted or injected straight into shell. The convention is inconsistent and fragile.
2. **State doesn't carry between bash blocks, and `lint-ok: C1` waivers hide it.** This affects handoff (UUID/WARM), setup (SETTINGS, HOSTS_TO_ADD, EXT_GITIGNORE_DONE, SEED_IMPORT_SUMMARY) and adjust-agent (AGENT). skill-lint passed all 16 commands, with 12 waived findings in setup and tdd-gate alone, and it doesn't catch use-before-define inside one block (setup MEMDB).
3. **The PDH one-liner is pasted 29 times across the slice (setup 9, adjust-agent 4, status 4).** That is a lot of prompt bloat and drift risk.
4. **Stub-removal version conflicts.** Docs disagree on when stubs were removed: "v1.0.0" (debug, mode, memory, spec) vs "v1.1.0" (README, migrate, status, debug:104). mode.md and the focus/blunt skills still say "deprecation stub".
5. **Stale posture wording.** `dontAsk` is still described as the ship default (docs/README:24, commands/setup.md:37, docs/commands/setup.md:9); the actual default is `auto`. The approval count still says 2 where it is now 3.
6. **Docs use cwd-relative `bash skills/...` paths** in manual, transcript-mirror, scheduled-retro and handoff-stm-dogfood. These break on marketplace installs.
7. **9 commands share a `name:` with a skill** (audit, bug-hunt, council, craft-loop, debug, doctor, epic, handoff, release-train). Which one `/dev-team:<name>` resolves to is unverified. If the skill wins, `/doctor` could load the check table instead of the runner.
8. **Destructive worktree release.** `/worktree release` and `/wrap-ticket` go through `branch -D` plus `--force`, and both the command's confirmation text and the docs understate that.
9. **3 broken anchors** (`#memory-configuration-memory-config` in manual, orchestrate runbook and commands/memory). The link checker found no other broken relative links.

### Enhancement proposals
| # | Title | Rationale | Concrete change | Effort | Pri |
|---|---|---|---|---|---|
| 1 | Fix `/setup team` bash | `/setup team` Steps 2-5b fail as written | `PLUGIN_DIR=$(bash "$PDH/skills/plugin-dir.sh" dir skills/memory-store/schema.sql)` in every step; compute MROOT before MEMDB; merge the Step 5b blocks; drop the C1 waivers | S | P0 |
| 2 | Fix epic `--autopilot` row | Contradicts skill + AGENTS.md | Rewrite commands/epic.md:36 to say "bump token ∈ {patch,minor,major} = seal-intent: persist `release_bump` + enable worktree (BC5)"; add the flag to docs/commands/epic.md | S | P0 |
| 3 | One arg-injection convention | `"$@"` is empty; `$ARGUMENTS` gets injected unquoted | Standard block: `ARGS=$(cat <<'__A__'\n$ARGUMENTS\n__A__\n)`, then parse; add a skill-lint rule banning bare `"$@"` in commands/*.md | M | P1 |
| 4 | Collapse handoff Step 1 into Step 3 | Parse state is lost across Bash calls | One bash block; use `mktemp` for `E`; emit `SPINE=` in the echo lines; exit 64 on unknown flag | S | P1 |
| 5 | tdd-gate hook hygiene | Shebang not on line 1; hook runs on every tool; fence looks runnable | Remove the preamble; put the file in a `sh` fence labeled "file content, do not execute"; add `"matcher":"Write\|Edit\|MultiEdit"`; add `argument-hint: "[on\|off\|status]"` and an unknown-arg usage message | S | P1 |
| 6 | Harden /recall | YAML list hint, empty topic, shell injection | Quote the hint; bare → usage; read the topic via heredoc into `TOPIC`; `grep -F -- "$TOPIC"`; escape LIKE; quote paths; align caps | S | P1 |
| 7 | Safe worktree release UX | Silent loss of unmerged commits | Before confirming, print `git log --oneline <base>..feat/<slug>` count and ahead-of-upstream; require typing the slug when unmerged; update docs for worktree and wrap-ticket | S | P1 |
| 8 | Fill doc coverage | 7 surfaces have no page; README mislabels | Add docs/commands/{adjust-agent,doctor,release-train,tdd-gate,backlog,ci-watch,release}.md; fix the README Docs column; extend docs-drift `cmd-index` to check docs/README and pages | M | P1 |
| 9 | Mark internal skills non-invocable | Internal skills surface as `/dev-team:*` | Add `user-invocable: false` to internal and backend skills; decide on the 9 name collisions (rename backend skill names or set them non-invocable) | S | P1 |
| 10 | Replace cwd-relative doc snippets | Break on installed plugin | Use the PDH + `plugin-dir.sh file …` pattern (as in migrate-to-v1) in manual, transcript-mirror, scheduled-retro and dogfood | S | P2 |
| 11 | Normalize stale wording | Version, posture and approval-count contradictions | Global pass: "deleted in v1.1.0"; `auto` posture; 3 approvals incl. escalation-gate; schema v4; 10 mappable agents; `--refresh` semantics; add `--skip-doctor` to the docs; fix the 3 anchors and the duplicate "12." | S | P2 |
| 12 | De-duplicate PDH stanza | About 29 copies of a 900-char line | Resolve once per command ("Step 0: resolve `PDH`/lib paths; reuse printed paths"), or ship `skills/pdh.sh`-style one-shot resolution the model runs once | M | P2 |
| 13 | Fix adjust-agent `grep -c` fallback | Dashboard misalignment (confirmed) | `COUNT=$(grep -c '^[0-9]' "$FILE" 2>/dev/null); COUNT=${COUNT:-0}`; mention finder/debugger mappability | S | P2 |
| 14 | skill-lint: intra-block use-before-define | Missed the setup MEMDB bug | New check flagging `$VAR` reads before assignment in the same fence when VAR is assigned later in that fence | M | P2 |
| 15 | Split internal/evidence docs | Maintainer logs mixed into user docs | Move handoff-stm-dogfood and permission-posture-matrix under `docs/internal/` (or label them); trim the bug-hunt and handoff pages to user essentials, linking to the specs | M | P3 |
| 16 | Complete flag docs | council, spec and doctor flags undocumented | Add council `--external/--council-tier/--why`, spec `reflect --phase/--report`, the full doctor group list, and release-train `dry-run` no-init (or document the init) | S | P3 |

Files with no issues: commands/bug-hunt.md (one nit only), docs/commands/{compact-transcript,craft-loop,refactor,status}.md, docs/runbooks/{specs,idea-to-plan}.md (idea-to-plan has one cosmetic nit).
