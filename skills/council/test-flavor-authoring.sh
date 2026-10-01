#!/usr/bin/env bash
# loadFlavor / flavorDelta strip authoring notes above ## Delta body.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
fail=0

out="$(node --input-type=module <<'JS'
import { flavorDelta, loadFlavor } from './skills/council/workflow.js'

const md = `---
name: toy
---
# toy
AUTHORING_NOTE_XYZ do not inject this.
## Delta body
You are the lens.
NEVER propose a fix.
`
const text = flavorDelta(md)
if (text.includes('AUTHORING_NOTE_XYZ')) {
  console.error('FAIL: authoring note leaked into flavor delta')
  process.exit(1)
}
if (text.includes('## Delta body')) {
  console.error('FAIL: Delta body marker leaked into flavor delta')
  process.exit(1)
}
if (!text.includes('NEVER propose a fix')) {
  console.error('FAIL: delta body was dropped')
  process.exit(1)
}
const marked = flavorDelta('[//]: # (AUTHORING_LINE_XYZ)\nKeep this sentence.\n')
if (marked.includes('AUTHORING_LINE_XYZ')) {
  console.error('FAIL: [//]: # authoring line leaked')
  process.exit(1)
}
if (!marked.includes('Keep this sentence.')) {
  console.error('FAIL: unmarked body was dropped')
  process.exit(1)
}
const injected = loadFlavor('paranoid-ic')
if (injected.includes('System-prompt delta injected')) {
  console.error('FAIL: paranoid-ic authoring note was injected')
  process.exit(1)
}
if (!injected.includes('PARANOID prior')) {
  console.error('FAIL: paranoid-ic delta body missing')
  process.exit(1)
}
console.log('OK: flavorDelta strips authoring notes')
console.log('OK: loadFlavor(paranoid-ic) omits the authoring note')
JS
)" || { echo "FAIL: flavor authoring"; echo "$out"; exit 1; }

printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q 'OK: flavorDelta strips authoring notes' || fail=1
printf '%s\n' "$out" | grep -q 'OK: loadFlavor(paranoid-ic) omits the authoring note' || fail=1

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
