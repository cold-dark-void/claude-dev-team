#!/usr/bin/env bash
# CDT-278 F26: branch name, duplicate step 12, anchor, review-and-commit,
# wrap-ticket distill hint, AGENTS.md finder /kickoff.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "OK: $*"; }
bad() { fail=$((fail + 1)); echo "FAIL: $*"; }

# Planted negative: the predicate still sees the old strings.
neg='feat/<ISSUE-ID>-<slug>'
if printf '%s\n' "$neg" | grep -qF 'feat/<ISSUE-ID>-<slug>'; then
  ok "control: old feat/<ID>-<slug> form is detectable"
else
  bad "control: branch-form detector is dead"
fi
if printf '%s\n' 'Claude commits automatically' | grep -qF 'commits automatically'; then
  ok "control: auto-commit claim is detectable"
else
  bad "control: auto-commit detector is dead"
fi

orch="$ROOT/docs/commands/orchestrate.md"
if grep -qF 'feat/<ISSUE-ID>-<slug>' "$orch"; then
  bad "orchestrate.md still says feat/<ISSUE-ID>-<slug>"
else
  ok "orchestrate.md dropped feat/<ISSUE-ID>-<slug>"
fi
if grep -qF 'feat/<ISSUE-ID>' "$orch"; then
  ok "orchestrate.md names feat/<ISSUE-ID>"
else
  bad "orchestrate.md does not name feat/<ISSUE-ID>"
fi
n12=$(grep -cE '^12\. ' "$orch" || true)
n13=$(grep -cE '^13\. ' "$orch" || true)
n14=$(grep -cE '^14\. ' "$orch" || true)
if [ "$n12" -eq 1 ] && [ "$n13" -eq 1 ] && [ "$n14" -eq 1 ]; then
  ok "orchestrate.md numbers steps 12, 13, and 14 once each"
else
  bad "orchestrate.md step numbers 12=$n12 13=$n13 14=$n14"
fi

runbook="$ROOT/docs/runbooks/orchestrate.md"
if grep -qF 'feat/POC-123-batch-export' "$runbook"; then
  bad "runbook still shows branch feat/POC-123-batch-export"
else
  ok "runbook dropped the slug branch example"
fi
if grep -qF 'branch feat/POC-123)' "$runbook" && grep -qF 'Branch: feat/POC-123' "$runbook"; then
  ok "runbook branch examples are feat/POC-123"
else
  bad "runbook branch examples are not feat/<ID>"
fi
if grep -qF 'setup.md#memory-configuration--memory-config' "$runbook"; then
  ok "runbook anchor is #memory-configuration--memory-config"
else
  bad "runbook anchor is not the setup.md heading fragment"
fi
if grep -qF 'setup.md#memory-configuration-memory-config)' "$runbook"; then
  bad "runbook still uses the single-dash anchor"
else
  ok "runbook dropped the single-dash anchor"
fi

rac="$ROOT/docs/commands/review-and-commit.md"
if grep -qF 'commits automatically' "$rac"; then
  bad "review-and-commit.md still says commits automatically"
else
  ok "review-and-commit.md does not say commits automatically"
fi
if grep -qF 'always ask' "$rac" && grep -qF '.worktrees/' "$rac"; then
  ok "review-and-commit.md says ask, and names the worktree halt"
else
  bad "review-and-commit.md misses the ask or the worktree halt"
fi
if grep -qF 'does not run this command' "$rac" && grep -qF 'does not call this command' "$rac"; then
  ok "review-and-commit.md does not claim orchestrate or wrap-ticket call it"
else
  bad "review-and-commit.md still claims a caller that does not exist"
fi

skill="$ROOT/skills/review-and-commit/SKILL.md"
if grep -qF 'calls `/review-and-commit` directly' "$skill"; then
  bad "review-and-commit skill still says orchestrate calls it"
else
  ok "review-and-commit skill dropped the false orchestrate call"
fi
if grep -qF 'do not call this command' "$skill"; then
  ok "review-and-commit skill says orchestrate and wrap-ticket do not call it"
else
  bad "review-and-commit skill does not correct the caller claim"
fi

wrap="$ROOT/docs/commands/wrap-ticket.md"
if grep -qF 'queues distillation' "$wrap"; then
  bad "wrap-ticket.md still says it queues distillation"
else
  ok "wrap-ticket.md does not say it queues distillation"
fi
if grep -qF 'Do not start distillation' "$wrap"; then
  ok "wrap-ticket.md says distillation is only a hint"
else
  bad "wrap-ticket.md does not say distillation is only a hint"
fi

agents="$ROOT/AGENTS.md"
row=$(awk -F'|' '$2 ~ /^[[:space:]]*`finder`[[:space:]]*$/ { print; exit }' "$agents")
if printf '%s\n' "$row" | grep -qF '/kickoff'; then
  ok "AGENTS.md finder row names /kickoff"
else
  bad "AGENTS.md finder row omits /kickoff ($row)"
fi

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
