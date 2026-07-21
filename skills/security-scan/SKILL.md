---
name: security-scan
description: |
    Optional host SAST (Semgrep / CodeQL) feed for security review. Fail-open
    when tools are missing. Agent-internal + review-and-commit / council
    security flavor. Zero required deps.
---

# Security Scan

Optional static-analysis feed. **Does not vendor Semgrep or CodeQL** — runs
them only if the host already has them on `PATH`. Inspired by professional
SAST workflows; methodology rewritten for MIT/dev-team (no third-party skill
text).

## When

| Caller | When |
|--------|------|
| `/review-and-commit` | Step 1c before investigators (always attempt; skip if tools missing) |
| Council `security` flavor | Prefer running scan first; cite tool output as evidence |
| Manual | `bash skills/security-scan/scan.sh [paths…]` |

Never hard-require tools. Never block commit solely because tools are absent.

## Run

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
SCAN=$(bash "$PDH/skills/plugin-dir.sh" file skills/security-scan/scan.sh)
bash "$SCAN"   # optional path args; default = feature-branch changed files
```

Exit code is **always 0** (fail-open). Stdout ends with a summary; artifacts
under `OUT_DIR=` (or `$SECURITY_SCAN_OUT`).

| Tool | Behavior |
|------|----------|
| `semgrep` | `--config=auto` on targets; SARIF when supported |
| `codeql` | Only if `CODEQL_DB_PATH` or `./codeql-db` exists — never creates DBs |
| neither | `SECURITY-SCAN: SKIP` line |

## Investigator protocol

When scan output exists:

1. Read summary + any SARIF/text artifacts
2. Map high-signal findings to `finding[]` with `tool_use_id` from Read/Bash
3. **Variant analysis** — for each confirmed sink (injection, secret, auth gap),
   Grep the repo for the same pattern outside the diff; emit related findings
   only with evidence
4. Do not re-state every low-severity linter nit; prefer exploit paths + PII

When scan is SKIP: proceed with LLM-only security review (existing flavor).

## Env

| Variable | Effect |
|----------|--------|
| `SECURITY_SCAN=0` | Callers skip invoking scan.sh entirely |
| `SECURITY_SCAN_OUT` | Artifact directory |
| `CODEQL_DB_PATH` | Existing CodeQL database directory |
