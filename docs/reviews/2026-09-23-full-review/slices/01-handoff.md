# Slice 01: `/handoff` subsystem review

Reviewer slice: `slices/01-handoff.txt` (74 files). The review was read-only; no repo file was modified.
Evidence was gathered by running all 19 `skills/handoff/*-test.sh`, `bash -n`, `shellcheck -S warning`, `py_compile`, JSON validation of every fixture, and two scratch probes (markdown injection and discover encoding).

## Slice summary

- **What it does:** `/handoff` builds an STM "compact seed" packet (State now → Through-line → appendix) from a Claude Code or Grok session transcript. The parent command parses arguments, discovers the session (warm), resolves the target root, checks the cache (cold), and prepares (`prepass.sh`). It then detaches one background agent that reads `SKILL.md`/`LIGHT.md`, mines events into `through_line.json`/`state.json`, and finalizes. Finalize runs `assemble.py`, which merges, dedups, and renders LLM-free, then writes the M8 cache. PreCompact rescue (`precompact-capture.sh`) is a separate deterministic path.
- **Overall grade: B-.** The deterministic engine is well built and heavily tested: `assemble.py`, `packet_dedup.py`, `packet_quality.py`, and `prepass.sh` have fail-soft design, atomic writes, uuid charset guards, stderr draining, and bounded caches. The weak spots are the LLM-facing layer and the test harness.
- **Test status:** 18 of 19 suites pass. **`detached-stub-test.sh` FAILS on master** (`commands/handoff.md is 12096B (cap 12000)`). The cause is the v1.18.14 PDH stanza change, which went unnoticed because **no handoff test is wired into CI** (`.github/workflows/smoke.yml` and `tools/smoke/run.sh` never run them). SPEC-018 line 201 claims the cap is "CI `wc -c`" enforced.
- **Biggest correctness risks:**
  1. Multi-line event text is rendered raw. A `\n## appendix` inside a quote forges sections and truncates the cold core print (verified).
  2. The command hard-depends on `jq`, which is undeclared. `MODE=$(jq …)` under `set -e` aborts silently when `jq` is missing.
  3. The warm cwd-newest fallback encodes the project dir with `s|/|-|g` instead of Claude's non-alnum→`-`. It never resolves for paths containing `.`, which includes every plugin-managed `.worktrees/<slug>` (verified).
- **Biggest prompt risk:** no skill file gives the detached agent a concrete, copy-pasteable git/finalize invocation. The parent's `export HANDOFF_DIR`/`FINALIZE_PRIOR_EVENTS` do not survive into the agent. `LIGHT.md` step 6 lists only `finalize --mode warm --light`, with no `--uuid/--events/--leaf/--prior-events/--slug`. Several step references point at steps that no longer exist (`Step 0`, `Step 1w`, `Step 4`, `Step 5b`, `Step 7`, `Step 8`).
- **Token cost:** `SKILL.md` is 52 KB (~13k tokens) and is read by every detached agent. 389 of the 457 non-blank lines in `LIGHT.md` are verbatim copies of `SKILL.md` lines. `SKILL.md` also carries the whole M10c light section, which `SKILL.md` itself says it never serves.
- **Test-quality issues:** some assertions are vacuous (`grep -qv`, the tautological AC1 ratio, the always-ok AC13 advisory). Three tests keep hand-copied clones of command logic ("keep in sync") instead of extracting it from the command. Some tests are GNU-only (`sha256sum`, `touch -d`, `find -printf`), so they will not run on macOS.
- **Docs:** the command page and the runbook are accurate in substance. They carry minor drift (the cache-HIT line wording and order) and stale branch/version references (`feat/CDT-92`, cache `1.0.3`).

## Per-file review

| File | Lines | Purpose (short) | Verdict | Findings (concise, with line numbers) |
|---|---|---|---|---|
| commands/handoff.md | 227 | `/handoff` parent stub: parse, discover, prepare, spawn | Issue | 12096 B > 12000 cap (SPEC-018:201; test red) (F1). Undeclared `jq` at L176/178/179/187; `MODE=$(jq…)` aborts under `set -e` (F3). Unquoted `set -- $ARGUMENTS` L18 globs (F13). Fixed `E=${TMPDIR:-/tmp}/handoff.err` L102 races and is predictable (F12). `--slug --full` makes slug `--full` L26-28 (F13). HOST read from bridge even on cold L179 (F15). Spawn payload names `SPINE=…` L208, but the parent never prints SPINE. WORK_DIR and the Grok temp file are never cleaned (F16). Frontmatter OK (`agent: build` is opencode-only). |
| docs/commands/handoff.md | 444 | User docs for /handoff | Minor | Cache-HIT sample L349 shows `(served from cache — session unchanged since last handoff)` before the core. The command prints the core first and then `(served from cache — session unchanged)` (L138) (F17). `jq`, which the command requires, is not listed. Otherwise consistent with the command, SKILL, and SPEC. |
| docs/runbooks/handoff-stm-dogfood.md | 304 | AC-16 human dogfood protocol | Minor | Stale refs: "cache `1.0.3` legacy" L64, "feat/CDT-79 dogfood" L69, "feat/CDT-92" L223 (F18). L200 claims `precompact-test.sh` covers the M14 carve-out: true, but only by static grep. Uses the PDH stanza correctly. |
| skills/handoff/LIGHT.md | 549 | `--light` thin miner profile | Issue | ~85% verbatim duplicate of SKILL.md (F7). "command Step 1" L30 vs "command Step 0" L114 contradict each other (F6). L223/235 say miner `haiku` when unset, but the spawn block L230 says "inherit session by default". Finalize step L64 gives no `--uuid/--events/--leaf/--slug/--prior-events` (F5). No frontmatter, which is fine because it is not a skill entrypoint. |
| skills/handoff/SKILL.md | 984 | Detached/in-session miner protocol, schemas, templates | Issue | Stale step refs: "Step 0" L157, "Step 5b" L211, "Step 1w" L784, and repeated "Step 7" (F6). M10c section L124-166 is a verbatim duplicate of LIGHT.md and dead for SKILL readers (F7). L67-68 diagram says "one Task" for the miner, contradicting detached INLINE. Git capture commands L688-691 lack `-C REPO_ROOT`, so a cold agent running in the invoker cwd captures the wrong repo (F9). No concrete finalize invocation mapping PLAN_JSON fields and parent echo lines to flags (F5). L117 "Prior events are verbatim" is contradicted by prefix-collapse copying the delta body (packet_dedup L101-102; SPEC L124 allows it). Frontmatter OK. Summary rules are triplicated (L282-285, L401-403, L564-575). |
| skills/handoff/assemble-quality-test.sh | 687 | Test 37/38 packet quality + dedup | Minor | AC13 advisory counts `ok` even when missed, L463-476 (F11). Stale comment "import FAIL until T2 is expected" ~L620. Otherwise strong behavioral coverage. PASS 52/0. |
| skills/handoff/assemble-test.sh | 1104 | assemble.py unit + CLI tests T0-T31 | Minor | Many python checks use `2>/dev/null` and fail opaquely. No test for multi-line/newline event bodies (F2 gap). Stale "RED before T1" comment at T28. PASS 61/0. |
| skills/handoff/assemble.py | 1248 | LLM-free event → STM packet assembler | Issue | `_display_body`/`render_event_line` L749-782 keep `\n`, so event text can inject `## appendix`. `extract_core` L1079-1097 then truncates the cold core (verified) (F2). Git blob is wrapped in a bare ``` fence L1035-1037, which breaks if the blob contains ```. Otherwise clean: validation, generation-aware ordering, `#N` collision uniquify, invent-guard. |
| skills/handoff/delta-prepare-test.sh | 250 | M8b `--since-leaf` prepare tests | Minor | T6 tests a hand-copied clone of the command's clear logic, not the command, and cites nonexistent "Step 8" L219 (F10). Dead no-op asserts L75-76, L164-165. PASS 19/0. |
| skills/handoff/detached-packet-test.sh | 128 | M19 AC8 packet identity | Minor | Only proves finalize determinism (same input twice). It is not a detached-vs-in-session comparison, as its header admits. PASS 8/0. |
| skills/handoff/detached-stub-test.sh | 329 | M19 stub static contract | Issue | **FAILS: AC1 12096B > 12000** (F1). L259 `set -u` should be `set -e`. L172 `--help` assertion is tautological. Stale "(RED until T2)" L2. Duplicates the Step-1 fence harness from light-gates-test. |
| skills/handoff/discover-warm-test.sh | 592 | Dual-host warm discovery tests | Minor | T12 L189 and G15 L301 use the same wrong `sed 's|/|-|g'` encoding as the implementation, which masks F4. GNU `touch -d` has a `-t` fallback (OK). SC2034 unused vars. PASS 32/0. |
| skills/handoff/discover-warm.sh | 627 | Resolve warm session id + transcript (Claude/Grok) | Issue | `cwd_newest_jsonl` L409 uses `s|/|-|g`, not Claude's `[^A-Za-z0-9]→-` (retro-gate/hint.sh L32-33 already documents this pitfall). Resolution fails for any cwd containing `.` or `_` (verified) (F4). Generic `$SESSION_ID` L434 is trusted as a Claude session id (F14). Adapted Grok temp L372 is never removed (F16). Unused `parent` L282. |
| skills/handoff/finalize-test.sh | 625 | prepass finalize/cache tests | Minor | T19 L370-378 "production wiring" only greps for strings. No instruction anywhere actually passes `plan.stats.est_tokens` → `--spine-tokens` (F5). PASS 39/0. |
| skills/handoff/fixtures/annotations-collision.json | 6 | Bare vs namespaced annotation trap | OK | Used by assemble-test T18/T19. |
| skills/handoff/fixtures/annotations-sample.json | 8 | Annotation sample incl. unknown id | OK | Used by assemble-test T1/T4. |
| skills/handoff/fixtures/delta-two-stage.jsonl | 8 | Two-stage transcript for since-leaf | OK | Used by delta-prepare and mirror-spine tests. |
| skills/handoff/fixtures/events-id-collision/state.json | 12 | Cross-file id `e1` collision | OK | Used by assemble-test T18-T20. |
| skills/handoff/fixtures/events-id-collision/through_line.json | 12 | Cross-file id `e1` collision | OK | Same as above. |
| skills/handoff/fixtures/events-merged-planted/state.json | 20 | Planted open/conflict | OK | merged-miner-ac2-test. |
| skills/handoff/fixtures/events-merged-planted/through_line.json | 47 | Planted 5 through-line kinds | OK | merged-miner-ac2-test. |
| skills/handoff/fixtures/events-product-surfaces/state.json | 12 | ship_gap facet | OK | assemble-test T30/T31 and light-preset AC4. |
| skills/handoff/fixtures/events-product-surfaces/through_line.json | 31 | product_surface facets | OK | Same as above. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac1-prefix/state.json | 20 | Prefix-collapse ≥40 | OK | assemble-quality T38. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac1-prefix/through_line.json | 12 | Killed-shown placeholder | OK | Same as above. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac2-short/state.json | 18 | Short prefix (<40) keeps both | OK | Same as above. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac2-short/through_line.json | 3 | Empty events | OK | Same as above. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac4-twin/state.json | 19 | open/conflict twin drop | OK | Same as above. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac4-twin/through_line.json | 3 | Empty events | OK | Same as above. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac5-distinct/state.json | 18 | Distinct conflict survives | OK | Same as above. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac5-distinct/through_line.json | 3 | Empty events | OK | Same as above. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac6-crosskind/state.json | 3 | Empty events | OK | Same as above. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac6-crosskind/through_line.json | 19 | Same body across kinds kept | OK | Same as above. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac7-zero-killed/state.json | 11 | Zero killed → `_none_` | OK | Same as above. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac7-zero-killed/through_line.json | 3 | Empty events | OK | Same as above. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac8-trio/state.json | 27 | Prefix + twin trio | OK | Same as above. |
| skills/handoff/fixtures/events-quality/dedup-residuals/ac8-trio/through_line.json | 12 | Kill in through-line | OK | Same as above. |
| skills/handoff/fixtures/events-quality/duplication/state.json | 13 | AC13 duplication | OK | assemble-quality AC13. |
| skills/handoff/fixtures/events-quality/duplication/through_line.json | 11 | AC13 duplication | OK | Same as above. |
| skills/handoff/fixtures/events-quality/no-summary/state.json | 11 | No wrapper summary | OK | assemble-quality AC12. |
| skills/handoff/fixtures/events-quality/no-summary/through_line.json | 11 | No wrapper summary | OK | Same as above. |
| skills/handoff/fixtures/events-quality/state.json | 20 | Quality packet state partition | OK | assemble-quality TAC1+. |
| skills/handoff/fixtures/events-quality/through_line.json | 55 | Quality packet + cited summary | OK | Same as above. |
| skills/handoff/fixtures/events-thrash.json | 130 | Main multi-hypothesis thrash fixture | OK | Used by 6 suites. It has no multi-line text case (see F2). |
| skills/handoff/fixtures/git-state.txt | 4 | Git blob stand-in | Minor | Lacks the `### git log …` section headers that `capture_git_state` emits, so it is unrealistic. It is also referenced from `prepass.sh` only in a comment. |
| skills/handoff/fixtures/grok-chat-mini.jsonl | 7 | Grok chat_history sample | OK | Adapter and discover tests. |
| skills/handoff/fixtures/mirror-spine/fork-child-main.md | 9 | Mirror main.md (fork suffix) | OK | mirror-spine T1.6. |
| skills/handoff/fixtures/mirror-spine/fork-child.jsonl | 4 | Fork transcript (forkedFrom) | OK | Same as above. |
| skills/handoff/fixtures/mirror-spine/grok-chat.jsonl | 5 | Grok mirror sample | OK | mirror-spine T1.8. |
| skills/handoff/fixtures/mirror-spine/plain-main.md | 19 | Mirror main.md with @refs | OK | mirror-spine T1.4. |
| skills/handoff/fixtures/mirror-spine/plain.jsonl | 4 | Plain transcript | OK | Same as above. |
| skills/handoff/fixtures/sidechain-noise.jsonl | 6 | Routine sidechain run | OK | sidechain-test T2. |
| skills/handoff/fixtures/sidechain-signal.jsonl | 6 | Signal-bearing sidechain | OK | sidechain-test T1. |
| skills/handoff/fixtures/spine-ac1-size.txt | 15 | Size-only AC1 fixture | Minor | Only feeds the tautological AC1 test (F11). |
| skills/handoff/fixtures/spine-mineable-mini.txt | 15 | Planted-thrash spine (manual AC2b) | OK | Only grep-checked in CI. |
| skills/handoff/grok-to-claude-jsonl-test.sh | 194 | Grok adapter tests | Minor | T0 L20 condition is a tautology (`-f && -x || -f`). T8 soft greps (`grep -qi 'fixture'`). PASS 21/0. |
| skills/handoff/grok-to-claude-jsonl.py | 102 | Thin CLI over grok_normalize | OK | Clean. |
| skills/handoff/leafrule.py | 27 | Single-source leaf rule | OK | Docstring says compute_leaf streams "assemble.py", meaning transcript-parse's assemble, not this skill's. Ambiguous but correct. |
| skills/handoff/light-defense-test.sh | 118 | Light cache defense | Minor | Tests a hand-copied PYDELTA clone ("Keep in sync") and cites nonexistent "Step 4" L3/L16 (F10). PASS 10/0. |
| skills/handoff/light-gates-test.sh | 276 | --light / --miner-model parse gates | OK | Correctly extracts the real Step-1 fence. Its harness duplicates detached-stub-test. PASS 22/0. |
| skills/handoff/light-preset-test.sh | 260 | Light finalize AC proof | Minor | Third PYDELTA clone (F10). `sha256sum` L131/157 is GNU-only (F19). PASS 18/0. |
| skills/handoff/light-static-test.sh | 245 | Light static contract | Minor | Enforces "byte-same" SKILL/LIGHT examples by spot-grep only, not a real sync check (F7). PASS 22/0. |
| skills/handoff/merged-miner-ac1-test.sh | 73 | "Cost ratio" AC1 | Issue | Tautological: asserts `S*1 ≤ 0.55*(S*2)`, which is always true for S>0. Zero signal (F11). |
| skills/handoff/merged-miner-ac2-test.sh | 146 | Planted kinds through finalize | OK | Real behavioral check. PASS 11/0. |
| skills/handoff/mirror-spine-test.sh | 510 | M3f mirror consume tests | Minor | GNU-only `find -printf` L22, `touch -d '2 minutes ago'` L46, `sha256sum` L48 (F19). Encoding `${CWD//\//-}` depends on the invoker cwd. Stale "RED until T2" L4/L206. PASS 86/0. |
| skills/handoff/packet_dedup.py | 162 | 3-pass dedup + kill placeholder | Minor | Prefix-collapse copies the delta body onto the prior event (L101-102). Allowed by SPEC L124, but contradicts SKILL L117 "never re-paraphrased". O(n²), fine at these sizes. |
| skills/handoff/packet_quality.py | 165 | Summary invent-guard, occupancy | Minor | Validated summary prose is emitted with newlines intact, the same injection vector as F2. |
| skills/handoff/precompact-capture.sh | 188 | PreCompact rescue artifact | Minor | Retention `sort -r` L165 is lexicographic, so seq ≥1000 would evict the newest. MROOT comes from the hook cwd L69-73, not `resolve-root.sh` (inconsistent with CDT-80, low risk). Fail-open contract honored. |
| skills/handoff/precompact-test.sh | 190 | M12-M18 rescue tests | Issue | Vacuous `grep -qv` L62 and L83: "payload stripped" and "u5 dropped" always pass (F11). T11b-T13 SKIP because the hooks live only in init-orchestration templates (not extracted). PASS 26/0/3 skip. |
| skills/handoff/prepass.sh | 1787 | prepare / cache-check / finalize engine | Minor | Runs `python3 assemble.py --help` up to 3× to soft-detect flags on a co-shipped file, L725-741, which is dead defensive code (F20). Exit 2 (invalid uuid, L308) is missing from the exit-code table L83-87. `int(HANDOFF_SPINE_TOKENS)` L1181 tracebacks on a non-numeric value. Runs the PDH stanza with a `find` over the plugin cache on every prepare L1102 instead of `$SCRIPT_DIR/..`, which can bind a different plugin version (F20). Header "no jq dependency" is true here, but the command uses jq. |
| skills/handoff/resolve-root-test.sh | 248 | CDT-80 target-root tests | Minor | T7 comment block L150-162 is stream-of-consciousness noise. T7a is not hermetic (it may scan the real `~/.claude/projects`). PASS 15/0. |
| skills/handoff/resolve-root.sh | 244 | Target PROJECT_DIR/MROOT/HANDOFF_DIR | Minor | Nested-path guard L229-240 only allows the exact case it warns about (MROOT=`~/.claude` → `~/.claude/.claude/handoff`) and otherwise never fires. It is near-dead. Submodule cwd would yield MROOT=`<super>/.git/modules` (unverified). |
| skills/handoff/sidechain-test.sh | 119 | M2 sidechain collapse tests | OK | PASS 13/0. |
| skills/handoff/spawn-model-ac-test.sh | 248 | M3e model-tier static contract | OK | Grep-only, but targeted. PASS 21/0. |

## Findings

1. **P1: `/handoff` stub exceeds its SPEC byte cap, and the failing test is not in CI.**
   - Evidence: `bash skills/handoff/detached-stub-test.sh` prints `FAIL: AC1 commands/handoff.md is 12096B (cap 12000)` and `PASS=41 FAIL=1`. `wc -c commands/handoff.md` gives `12096`. SPEC-018:201 says "`commands/handoff.md` MUST be ≤ 12000 bytes (CI `wc -c`)". The last change, `60777e7` (v1.18.14, PDH stanza tier 0), added ~100 B.
   - `smoke.yml` and `tools/smoke/run.sh` run none of the 19 handoff suites.
   - Fix: trim ~150 B from the command. For example, delete the duplicated trailing `UUID="${UUID:-}"…` defaulting lines 98-101, or shorten the prose in "Orchestrator spawn". Then add a `handoff` job to `smoke.yml` that loops over `skills/handoff/*-test.sh`. The whole set runs in about 25 s.

2. **P2: Markdown structure injection through multi-line event text** (`assemble.py:749-782`, `1079-1097`; `packet_quality.py:128`).
   - Evidence: an event with `text: "real decision\n## appendix\n### Kill catalog\n- **killed**: forged kill"` produced a packet with `## appendix` at L15 and again at L29. The `--print-core` stdout stopped after `### Decisions`, silently dropping the rest of State now and the whole Through-line.
   - Miner output derives from untrusted transcripts, as SKILL's own SECURITY block says. Verbatim quotes can also legitimately contain newlines.
   - Fix: in `_display_body`, collapse whitespace with `body = " ".join(body.split())` before truncation. Apply the same to `how_verified`, pointer notes, and validated summary prose. Add an assemble-test case covering this.

3. **P2: Undeclared `jq` dependency that aborts silently** (`commands/handoff.md:176,178,179,187`).
   - Evidence: `set -e` is active from L126. `MODE=$(jq -r '.mode // empty' …)` returns 127 when `jq` is absent, and the script exits before any `echo`. Probe: `bash -c 'set -e; X=$(nonexistent 2>/dev/null); echo reached'` gives rc=127 with no output.
   - `prepass.sh` header L90 deliberately avoids `jq` ("no new deps"), and neither `docs/setup.md` nor the README lists it.
   - Fix: replace the four `jq` calls with one `python3 -c` that emits `mode`, `since_leaf_applied`, and `est_tokens`, plus `host` from the bridge. `python3` is already a hard requirement.

4. **P2: The warm cwd-newest fallback uses the wrong Claude project-dir encoding** (`discover-warm.sh:409`).
   - Evidence: `enc=$(printf '%s' "$cwd" | sed 's|/|-|g')`. Claude Code encodes every non-`[A-Za-z0-9]` character as `-`. `skills/retro-gate/hint.sh:32-33` documents exactly this ("s|/|-|g alone misses '.'"), and `resolve-root.sh:148` agrees.
   - Probe: with cwd `…/my.proj/.worktrees/wt` and a correctly encoded projects dir, discover exits 1 with "could not resolve this session's id".
   - Every plugin-managed worktree (`.worktrees/<slug>`, per AGENTS.md) hits this. The tests (`discover-warm-test.sh:189,301`) replicate the bug, which masks it.
   - Fix: `sed 's|[^A-Za-z0-9]|-|g'` in both the script and the tests. Add a test cwd containing `.`.

5. **P1 (partly unverified at runtime): The detached/light agent has no concrete finalize contract.**
   - `SKILL.md:80-82,744-748` and `LIGHT.md:64` give only a flag synopsis (`LIGHT.md` has just `prepass.sh finalize --mode warm --light`).
   - The parent's `export HANDOFF_DIR MROOT PROJECT_DIR` (cmd L135) and `export FINALIZE_PRIOR_EVENTS` (L167) do not survive into the agent's shells. The command's own M19.7 comment concedes "export does not survive".
   - Nothing tells the agent to:
     - pass `--leaf <plan.leaf_uuid>`. Without it, finalize re-streams via `locate`, which fails for Grok adapted transcripts in TMPDIR, so the packet is left uncached.
     - pass `--prior-events $PRIOR_EVENTS_FILE`.
     - pass `--spine-tokens <plan.stats.est_tokens>`. finalize-test T19 "wiring" is grep-only.
     - export `HANDOFF_DIR`, without which finalize resolves by uuid.
     - pass `--slug $SLUG` or `--mode $HANDOFF_MODE`.
   - Fix: add one canonical executable fenced block to SKILL.md ("## Finalize (copy verbatim)") that reads `PLAN_JSON` with python3 and runs `HANDOFF_DIR=… bash "$PREPASS" finalize --uuid … --events "$EVENTS_DIR" --leaf … --slug … --mode … [--prior-events …] [--annotations …] [--light] --spine-tokens …`. Reference it from LIGHT.md. Add a static test that greps for every required flag.

6. **P2: Stale or contradictory step references across the prompt files.**
   - SKILL.md: "command Step 0" (L157), "Step 5b" (L211), "Command Step 1w" (L784), and "Step 7" (L108, 119, 609).
   - LIGHT.md: "command Step 1" at L30 but "Step 0" at L114.
   - Elsewhere: `prepass.sh:20,320,621` ("Step 1w", "Step 0"), `light-defense-test.sh:3,16` ("Step 4"), `delta-prepare-test.sh:219` ("Step 8"), SPEC-018:78,124 ("Step 4", "Step 7").
   - The command now has only Steps 1, 1a, 2, and 3, plus the "Orchestrator spawn" and "In-session fallback" sections.
   - Fix: replace step numbers with section names (e.g. "command § Step 1 parse", "SKILL § Annotation pass"). Add a static test that fails on `Step [0-9]+[a-z]?` tokens that don't match a heading in `commands/handoff.md`.

7. **P2: Massive prompt duplication between SKILL.md and LIGHT.md, and inside SKILL.md.**
   - Evidence: 389 of LIGHT's 457 non-blank lines (23.3 KB) appear verbatim in SKILL.md. SKILL's `### M10c — light warm preset` (L124-166) is byte-identical to LIGHT L81-123, yet SKILL.md says `--light uses skills/handoff/LIGHT.md only — never this file` (L39).
   - Within SKILL.md, the summary rule is written three times (L282-285, L401-403, L564-575).
   - `light-static-test.sh` T11 only spot-greps a few strings, so edits drift silently.
   - Fix: extract the shared blocks (SECURITY, common preamble, merged-miner prompt, chunk-summarizer) into `skills/handoff/miner-prompt.md`. Both SKILL and LIGHT then say "Read miner-prompt.md". Alternatively, keep the duplication but add a test that diffs the marked shared regions. Delete the M10c section from SKILL.md. Expected saving: ~4-6k tokens per detached run.

8. **P2: `HOST` for miner-tier mapping is read from the warm bridge even on cold** (`commands/handoff.md:179`).
   - Docs L261 and SKILL L446 say "Cold / missing / unknown host uses the Claude column".
   - Evidence: `HOST=$(jq -r '.host // "claude"' "$HANDOFF_DIR/.live-session.json" …)` is unconditional. After a Grok warm capture in the same repo, a cold `--miner-model fast` on Claude resolves to `fast` (Grok identity). The host then rejects it and falls back to inherit, which is a silent cost regression.
   - Fix: `[ "$HANDOFF_MODE" = warm ] && HOST=… || HOST=claude`.

9. **P2: The SKILL git capture recipe is not anchored to the target repo** (`SKILL.md:686-692`).
   - The commands are plain `git log/status/diff`. For cold `/handoff <uuid>` invoked from another directory (a documented use case), an agent following this section captures the invoker's repo.
   - `prepass.sh finalize` correctly uses `git -C "$REPO_ROOT"` when `--git-state` is omitted, as does the miner M5 block (L526).
   - Fix: change the recipe to `git -C "$MROOT" …`, or say "omit `--git-state`; finalize captures from the target root".

10. **P2: Tests validate copies of command logic, not the command.**
    - `light-defense-test.sh:16` and `light-preset-test.sh:15` embed their own PYDELTA ("Keep in sync"). `delta-prepare-test.sh:194-225` re-implements the since-leaf clear with python, while the command uses `jq -e`, a different implementation.
    - Drift between the command and these clones would go undetected.
    - Fix: extract the heredoc from `commands/handoff.md`, as `extract_step1_fence` already does for Step 1 (e.g. an awk extract between `<<'PYDELTA'` and `^PYDELTA`), and execute that.

11. **P3: Vacuous or tautological assertions.**
    - `precompact-test.sh:62,83`: `grep -qv PATTERN file` succeeds whenever any line lacks the pattern, so "payload stripped" and "u5 dropped" can never fail. Fix: `! grep -q`.
    - `merged-miner-ac1-test.sh`: arithmetic identity `S ≤ 1.1·S`. Fix: delete it, or replace it with a static check that SKILL/LIGHT contain exactly one miner spawn contract.
    - `assemble-quality-test.sh:463-476`: AC13 is counted `ok` on WARN. Fix: report it as a separate WARN count.
    - `detached-stub-test.sh:172`: `--help` check `|| [ "$RC" -eq 0 ]` is always true.
    - `detached-stub-test.sh:259`: `set -u` where `set -e` was intended.

12. **P3: Predictable shared error file** (`commands/handoff.md:102`). `E="${TMPDIR:-/tmp}/handoff.err"` is a fixed name. Concurrent `/handoff` runs clobber each other's diagnostics, and on a multi-user host with `TMPDIR` unset it is a symlink-clobber target. Fix: `E=$(mktemp "${TMPDIR:-/tmp}/handoff.err.XXXXXX")`.

13. **P3: Argument parsing edge cases** (`commands/handoff.md:18,26-28`).
    - `set -- $ARGUMENTS` is subject to pathname expansion: `/handoff *` expands to cwd filenames and yields a bogus "uuid".
    - `--slug` accepts a following flag as its value (`--slug --full` sets SLUG=`--full` and drops `--full`), unlike `--miner-model`, which rejects `-*`.
    - Fix: `set -f` before `set --`. Apply the `case "${2:-}" in ""|-*)` guard to `--slug` too.

14. **P3: Generic `$SESSION_ID` env is trusted as the live session id** (`discover-warm.sh:434`, plus Grok lookup L307). `SESSION_ID` is a common variable name in user shells and CI. If it is set, warm discovery may mine an unrelated session. Fix: drop `SESSION_ID` from the precedence list, or require `HANDOFF_SESSION_ID`.

15. **P3: Cold core print and doc disagree on order and wording** (`commands/handoff.md:138` vs `docs/commands/handoff.md:343-352`). The command prints the core, then `(served from cache — session unchanged)`. The docs show the note first, with "…since last handoff". Fix: align the docs to the actual output.

16. **P3: Temp artifacts leak.** Nothing removes `WORK_DIR` (cmd L168; it holds the spine, i.e. a full session text copy) or the adapted Grok JSONL (`discover-warm.sh:372`). The command only says "MUST NOT rm before agent completion". Fix: have the agent's final step `rm -rf "$WORK_DIR"` (and the Grok temp file). Alternatively, place them under `$HANDOFF_DIR/tmp/` with pruning.

17. **P3: Stale version and branch references in the runbook** (`handoff-stm-dogfood.md:64,69,223`). "cache `1.0.3` legacy", "feat/CDT-79 dogfood", "feat/CDT-92". The plugin is at v1.18.14. Fix: generalize to "an older cached version" and "this repo / released plugin".

18. **P3: GNU-only tooling in tests.** `light-preset-test.sh:131,157` and `mirror-spine-test.sh:48` use `sha256sum`. `mirror-spine-test.sh:46` uses `touch -d '2 minutes ago'`, and L22 uses `find -printf`. These fail on stock macOS. Fix: `shasum -a 256` fallback; `touch -t $(date -v-2M …)`, or python `os.utime`; replace `-printf` with a python stat walk.

19. **P3: prepass soft-detect overhead and plugin-root indirection** (`prepass.sh:725-741,1102`).
    - `python3 assemble.py --help | grep` runs up to three times per finalize to detect flags on a file shipped in the same directory. Dead compatibility code costing ~150 ms.
    - `prepare` runs the full PDH stanza, including a `find ~/.claude/plugins/cache`, to locate the sibling `transcript-mirror` skill. It could resolve the wrong plugin version, while `$SCRIPT_DIR/../transcript-mirror` is authoritative.
    - Fix: drop the soft-detect. Prefer `$SCRIPT_DIR/..` first and use PDH only as a fallback.

20. **P3: `resolve-root.sh` nested-write guard is effectively dead** (L229-240). It only matches when `HANDOFF_DIR` is under `~/.claude/.claude`, and then allows exactly the `MROOT=~/.claude` case, which produces `~/.claude/.claude/handoff`, the path the docs say must never be written. Fix: decide the intended policy: refuse `MROOT == $HOME/.claude`, or delete the guard.

21. **P3 (repo-wide, unverified impact): Skill and command share the name `handoff`.** `skills/handoff/SKILL.md` has `name: handoff`, the same as `commands/handoff.md`, and has no `user-invocable: false` / `disable-model-invocation`. The same pattern exists for 8 other skills. Whether this shadows the command in slash-suggestion lists is unverified. Fix: consider `name: handoff-miner`, or add the invocability flag if the loader supports it.

## Enhancement proposals

| # | Proposal | Effort | Impact |
|---|---|---|---|
| E1 | Add a `handoff` CI job to `smoke.yml` looping over `skills/handoff/*-test.sh` (~25 s total). This would have caught F1 and guards the 500+ assertions already written. | S | High |
| E2 | Single `miner-prompt.md` shared by SKILL and LIGHT, and delete SKILL's M10c section. SKILL then shrinks from ~52 KB to ~30 KB and LIGHT from ~28 KB to ~6 KB. Saves ~5k+ tokens per detached run and removes the drift class behind F7. | M | High |
| E3 | Canonical "Finalize (copy verbatim)" fenced block in SKILL.md, fed from `PLAN_JSON` and the parent's echoed values (fixes F5 and F9). Add a static test for required flags. | S | High |
| E4 | Sanitize newlines in every rendered string in `assemble.py` (F2), plus a regression test using a quote with `\n## ` inside. | S | High |
| E5 | Replace `jq` in the command with one python3 helper that prints `MODE SLA ET HOST` (F3, F8). It also cuts ~300 B from the command, which fixes F1. | S | Med-High |
| E6 | Test harness dedup: create `skills/handoff/test-lib.sh` (ok/bad/section/extract_step1_fence/run_parse/extract_heredoc). About 8 suites copy these helpers today. Make the PYDELTA and SLA tests execute code extracted from the command (F10). | M | Med |
| E7 | Remove zero-value tests (`merged-miner-ac1-test.sh` and its fixture) and fix the vacuous `grep -qv` (F11). | S | Low-Med |
| E8 | Make tests macOS-portable (F18) and hermetic: set `CLAUDE_PROJECTS_DIR` and `HOME` in resolve-root T7a, and stop depending on `$(pwd)` in mirror-spine. | S | Med |
| E9 | Extract the PreCompact hook templates from `skills/init-orchestration/SKILL.md` in `precompact-test.sh`, so T11b-T13 run instead of SKIP. | M | Med |
| E10 | Cleanup contract: the agent removes `WORK_DIR` and the Grok temp file on completion; the parent removes them on cold HIT and on early exits (F16). | S | Low-Med (privacy hygiene) |
| E11 | Static "step reference" lint: any `Step N` token in handoff files must match a heading in `commands/handoff.md` (F6). | S | Med |

## Coverage attestation

- Files in slice list (`slices/01-handoff.txt`): **74**
- Rows in the Per-file review table: **74** (the counts match; every file was read in full, and large files were read in chunks)
- Test execution: 19/19 suites run; 18 pass; `detached-stub-test.sh` fails (1 assertion); `precompact-test.sh` has 3 environment SKIPs.
