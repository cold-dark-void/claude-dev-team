# Test execution log — 2026-09-23 (master @ 60777e7, v1.18.14)

Environment: Linux container, bash 5.2.21, run as **root** (uid 0), no `sqlite3` on PATH for the CI-gate run, `CLAUDE_CODE_VERSION` set.

## A. CI-wired gates (`.github/workflows/smoke.yml`) — 10 commands

```
rc=0 t=1s :: bash tools/smoke/run.sh :: PASS /home/user/claude-dev-team/skills/wrap-ticket/prune-remote.sh 139 checked, 0 failed 
rc=0 t=0s :: bash skills/skill-lint/check-skill-bash.sh :: 299 findings, 299 waived 
rc=0 t=1s :: bash skills/docs-drift/check-docs-drift.sh :: 0 findings, 0 waived 
rc=0 t=2s :: bash skills/retro-gate/test.sh :: ---- PASS=27 FAIL=0 
rc=0 t=1s :: bash skills/release/test-bump-class.sh ::  16 passed, 0 failed 
rc=0 t=0s :: bash skills/release/check-bump-class.sh --commit HEAD :: bump-class: no new commands/*.md — ok 
rc=127 t=1s :: bash skills/memory-store/test-seed-pack.sh ::   FAIL M8 rejected: missing [rejected=1] skills/memory-store/test-seed-pack.sh: line 229: sqlite3: command not found 
rc=0 t=1s :: bash skills/wrap-ticket/prune-remote-test.sh ::  PASS=61 FAIL=0 
rc=0 t=2s :: bash skills/plugin-dir-test.sh ::  PASS=189 FAIL=0 
rc=0 t=1s :: bash skills/agent-memory/sync-includes-test.sh ::  PASS=58 FAIL=0 
```

## B. Test scripts present in the repo but NOT wired into CI — 70 scripts

Passing: 62. Failing: 8.

```
rc=0 t=1s install-test.sh :: passed=17 failed=0
rc=0 t=2s skills/audit/test.sh :: 37 passed, 0 failed
rc=0 t=3s skills/autopilot/test.sh :: PASS=311 FAIL=0
rc=0 t=2s skills/backlog/reconcile-test.sh :: Results: 68 passed, 0 failed
rc=0 t=1s skills/backlog/test.sh :: Results: 98 passed, 0 failed
rc=0 t=1s skills/bug-hunt/test.sh :: PASS=206 FAIL=0
rc=0 t=1s skills/ci-watch/test-poll.sh :: Results: PASS=7 FAIL=0
rc=0 t=1s skills/council/test-finalize-missing-tid.sh :: PASS=29 FAIL=0
rc=0 t=2s skills/council/test-tier-engine.sh :: ALL PASS
rc=0 t=3s skills/council/test-tier-grade.sh :: ALL PASS
rc=1 t=0s skills/council/test-workflow-static.sh :: OK: judge tools empty
rc=0 t=2s skills/docs-drift/test.sh :: docs-drift tests: 65 passed, 0 failed
rc=0 t=22s skills/doctor/test.sh :: doctor tests: 102 pass / 0 fail
rc=0 t=15s skills/epic/test.sh :: PASS=745 FAIL=0
rc=0 t=2s skills/handoff/assemble-quality-test.sh :: assemble-quality-test: 52 passed, 0 failed
rc=0 t=2s skills/handoff/assemble-test.sh :: assemble-test: 61 passed, 0 failed
rc=0 t=1s skills/handoff/delta-prepare-test.sh :: delta-prepare-test: 19 passed, 0 failed
rc=0 t=0s skills/handoff/detached-packet-test.sh :: PASS=8 FAIL=0
rc=1 t=0s skills/handoff/detached-stub-test.sh :: PASS=41 FAIL=1
rc=0 t=2s skills/handoff/discover-warm-test.sh :: discover-warm-test: 32 passed, 0 failed
rc=0 t=5s skills/handoff/finalize-test.sh :: finalize-test: 39 passed, 0 failed
rc=0 t=0s skills/handoff/grok-to-claude-jsonl-test.sh :: grok-to-claude-jsonl-test: 21 passed, 0 failed
rc=0 t=1s skills/handoff/light-defense-test.sh :: light-defense-test: 10 passed, 0 failed
rc=0 t=0s skills/handoff/light-gates-test.sh :: light-gates-test: 22 passed, 0 failed
rc=0 t=1s skills/handoff/light-preset-test.sh :: light-preset-test: 18 passed, 0 failed
rc=0 t=0s skills/handoff/light-static-test.sh :: PASS=22 FAIL=0
rc=0 t=0s skills/handoff/merged-miner-ac1-test.sh :: PASS=6 FAIL=0 S=1024 baseline=2048 merged=1024 ratio=50%
rc=0 t=0s skills/handoff/merged-miner-ac2-test.sh :: merged-miner-ac2-test: 11 passed, 0 failed
rc=0 t=5s skills/handoff/mirror-spine-test.sh :: mirror-spine-test: 86 passed, 0 failed
rc=0 t=2s skills/handoff/precompact-test.sh :: precompact tests: 26 passed, 0 failed, 3 skipped
rc=0 t=1s skills/handoff/resolve-root-test.sh :: resolve-root-test: PASS=15 FAIL=0
rc=0 t=1s skills/handoff/sidechain-test.sh :: sidechain-test: 13 passed, 0 failed
rc=0 t=0s skills/handoff/spawn-model-ac-test.sh :: PASS=21 FAIL=0
rc=0 t=1s skills/init-orchestration/escalation-gate-test.sh :: escalation-gate-test: PASS=40 FAIL=0
rc=0 t=0s skills/init-orchestration/test-disclose-force.sh :: === results: PASS=33 FAIL=0 ===
rc=0 t=1s skills/init-orchestration/test-normalize-hook-paths.sh :: === results: PASS=32 FAIL=0 ===
rc=0 t=0s skills/init-orchestration/test-orch-allowlist.sh :: === results: PASS=24 FAIL=0 ===
rc=0 t=2s skills/init-orchestration/test-signing-sandbox.sh :: === results: PASS=88 FAIL=0 ===
rc=0 t=0s skills/init-orchestration/test-sweep-legacy-orphans.sh :: === results: PASS=47 FAIL=0 ===
rc=0 t=0s skills/memory-store/test-migrate.sh :: === results: PASS=38 FAIL=0 ===
rc=1 t=5s skills/metrics/test.sh :: PASS=24 FAIL=1
rc=0 t=2s skills/model-map/effort-test.sh :: PASS=45 FAIL=0
rc=0 t=5s skills/model-map/effort-write-test.sh :: PASS=66 FAIL=0
rc=0 t=0s skills/model-map/spawn-site-test.sh :: PASS=121 FAIL=0
rc=0 t=2s skills/model-map/test.sh :: PASS=30 FAIL=0
rc=0 t=2s skills/model-map/write-model-test.sh :: PASS=51 FAIL=0
rc=0 t=1s skills/notify/webhook-test.sh :: Results: 8 passed, 0 failed
rc=1 t=3s skills/orchestrate/router-static-test.sh :: PASS=15 FAIL=1
rc=0 t=4s skills/orchestrate/task-store-test.sh :: task-store-test: PASS=33 FAIL=0
rc=1 t=1s skills/release-train/test-integration.sh :: PASS=11 FAIL=2
rc=0 t=2s skills/release-train/test.sh :: PASS=64 FAIL=0
rc=0 t=1s skills/release/test-ship-history.sh :: ship-history PASS=33 FAIL=0
rc=0 t=3s skills/release/test.sh :: PASS=50 FAIL=0
rc=1 t=0s skills/retro-gate/friction-capture-test.sh :: FAIL: missing /home/user/claude-dev-team/.claude/hooks/friction-capture.sh
rc=0 t=0s skills/retro-gate/scheduled-lock-test.sh :: PASS=8 FAIL=0
rc=1 t=0s skills/retro-gate/scheduled-retro-test.sh :: PASS=10 FAIL=1
rc=0 t=0s skills/retro-gate/trial-meta-test.sh :: PASS=21 FAIL=0
rc=0 t=1s skills/retro-gate/trial-review-test.sh :: PASS=19 FAIL=0
rc=0 t=2s skills/retro-gate/write-scheduled-report-test.sh :: PASS=22 FAIL=0
rc=0 t=1s skills/skill-lint/test.sh :: skill-lint tests: 56 passed, 0 failed
rc=0 t=5s skills/transcript-mirror/compact-transcript-test.sh :: operator-store: unchanged n=0 root=/root/.claude/transcript
rc=0 t=4s skills/transcript-mirror/summarize-transcript-test.sh :: operator-store: unchanged n=0 root=/root/.claude/transcript
rc=1 t=17s skills/transcript-mirror/test.sh :: PASS=224 FAIL=3
rc=0 t=4s skills/transcript-mirror/transcript-sync-test.sh :: PASS=35 FAIL=0
rc=0 t=1s skills/transcript-parse/discover-host-test.sh :: discover-host-test: 10 passed, 0 failed
rc=0 t=1s skills/transcript-parse/hosts-grok-locate-test.sh :: 23 passed, 0 failed
rc=0 t=2s skills/transcript-parse/test-hosts.sh :: 28 passed, 0 failed
rc=0 t=8s skills/validate-memory/test-reconcile.sh :: Results: 19 passed, 0 failed
rc=0 t=2s skills/worktree-lib-test.sh :: Results: PASS=60 FAIL=0
rc=0 t=4s tools/smoke/test.sh :: smoke bite-test: 35 passed, 0 failed
```
