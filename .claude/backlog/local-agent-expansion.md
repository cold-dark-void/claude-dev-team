# Local-agent expansion: /debug + /refactor consumers, egress allowlist

**Status**: PENDING

## Problem

SPEC-019 shipped the offload engine with two planned extensions left unwired: `/debug` and `/refactor` are documented as future consumers of `skills/local-agent/run.sh` (v0.37.3 notes), and the bubblewrap sandbox deliberately does not restrict network egress (v0.37.2 notes an egress allowlist as a separate future ticket).

## Goal

Two follow-on tickets on the SPEC-019 line:
1. Wire `/debug` (patch fast-path) and `/refactor inline` to route eligible mechanical steps through the local agent with the same machine-check + two-cap review loop `/local-do` uses.
2. Add optional network egress restriction to the bwrap wrapper (allowlist or `--unshare-net` when the task needs no network), preserving the graceful-fallback and exit-code contract.

## Implementation Notes

- Reuse the `/local-do` review-loop shape rather than orchestrate's (standalone commands, no task DAG).
- Egress: probe whether opencode needs network for local models (ollama endpoint is localhost — `--unshare-net` may break it; bind or allowlist accordingly).

## Affects

`skills/debug/`, `skills/refactor/`, `skills/local-agent/run.sh`, `specs/core/SPEC-019-local-agent-offload-via-opencode.md`.

## Effort

M

## Notes

Source: 2026-07-03 ideation session (idea #8). Both extensions are already named in shipped changelog/spec text as deferred work.

---

*Added: 2026-07-03*
