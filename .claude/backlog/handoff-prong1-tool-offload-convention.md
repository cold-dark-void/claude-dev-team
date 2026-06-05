# Handoff — Prong-1 tool-offload AGENTS.md convention

**Status**: PENDING

## Problem
SPEC-018 shipped the *recovery* prong (cold/warm `/handoff`). The *prevention* prong from the brainstorm — keeping the main context clean so sessions hit the ~70% wall far later — was deferred. Tool I/O (file reads, bash output) is ~88% of session bytes and pollutes the main window.

## Goal
A standing tool-offload discipline: delegate multi-file reads / high-output commands to subagents that return conclusions, not dumps. Delivered as an AGENTS.md rule + optional per-agent directive (convention; no native CC toggle).

## Implementation Notes
- AGENTS.md rule: "delegate any multi-file read or high-output command to an Explore subagent; bring back findings only."
- Optional per-agent directives via /adjust-agent for the 7 team agents.
- The /handoff extractor fan-out already dogfoods this pattern.

## Affects
- AGENTS.md
- per-agent directives

## Effort
Low (convention/doc)

---

*Added: 2026-06-05*
