# /tdd-gate

Hook-based TDD enforcement toggle. When enabled, a `PreToolUse` hook blocks
Write/Edit to implementation files unless a corresponding test file exists.
Graduated enforcement per session: hint (1st attempt) → warning (2nd) → hard
block (3rd+). Deterministic, not probabilistic.

## Usage

```
/tdd-gate on
/tdd-gate off
/tdd-gate status
```

| Args | Action |
|------|--------|
| `on` | Install the PreToolUse hook |
| `off` | Remove the PreToolUse hook |
| `status` | Show current state (also the bare form) |

## How it works

The hook intercepts Write and Edit tool calls. For each target file it checks
whether a corresponding test file exists; if not, it hints, warns, then blocks
(exit 2), telling the agent to write a failing test first.

**Test file detection** (checked in order):

| Source file pattern | Expected test file(s) |
|--------------------|-----------------------|
| `src/foo.ts` | `src/foo.test.ts`, `src/foo.spec.ts`, `test/foo.test.ts`, `tests/foo.test.ts` |
| `src/foo.js` | `src/foo.test.js`, `src/foo.spec.js`, `test/foo.test.js`, `tests/foo.test.js` |
| `src/foo.py` | `src/test_foo.py`, `tests/test_foo.py`, `test/test_foo.py`, `src/foo_test.py` |
| `pkg/foo.go` | `pkg/foo_test.go` |
| `src/foo.rs` | `src/foo_test.rs`, `tests/foo.rs` |

**Always allowed** (never blocked): test files themselves, config files
(`*.json`, `*.yaml`, `*.yml`, `*.toml`, `*.md`, `*.txt`), CI/CD files, lock
files, type definitions, migration files, `specs/**`, `.claude/**`, shell
scripts, and build files.

State lives in `.claude/settings.json` plus the hook script under
`.claude/hooks/` (local, gitignored — regenerate via `/setup orchestration`).

## See also

- [`/setup orchestration`](setup.md) — installs the hook templates this toggles
