#!/usr/bin/env bash
# WP 2-09 — refuters are told to read untracked files, and workflow.js maps a
# porcelain stub onto that list. No new prompt variable.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
if grep -q 'git status --porcelain' "$ROOT/skills/fix-ticket/prompts/refute.md" \
  && grep -q '??' "$ROOT/skills/fix-ticket/prompts/refute.md"; then
  echo "OK: refute.md tells the refuter to read untracked files"
else
  echo "FAIL: refute.md missing porcelain / ?? instruction"
  fail=1
fi
if grep -q '{{UNTRACKED}}' "$ROOT/skills/fix-ticket/prompts/refute.md"; then
  echo "FAIL: refute.md added an undeclared variable"
  fail=1
else
  echo "OK: refute.md adds no new variable"
fi
cd "$ROOT"
node --input-type=module <<'JS'
import { untrackedFromPorcelain, refuteEvidence } from './skills/fix-ticket/untracked.js'
const files = untrackedFromPorcelain(' M tracked.js\n?? new.js\n?? dir/a.txt\n?? newdir/\n?? "my file.txt"\n')
if (files.join(',') !== 'new.js,dir/a.txt,my file.txt') throw new Error('paths: ' + files.join(','))
const ev = refuteEvidence('?? new.js\n')
if (!ev.includes('git status --porcelain')) throw new Error('instruction missing')
if (!ev.includes('Untracked files:')) throw new Error('evidence heading missing')
if (!ev.includes('- new.js')) throw new Error('stub path missing: ' + ev)
console.log('OK: workflow.js maps a porcelain stub into the refuter evidence')
JS
exit $fail
