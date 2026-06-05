# Handoff — deeper sidechain reconstruction

**Status**: PENDING

## Problem
The pre-pass collapses isSidechain runs to a one-line outcome + pointer (defensive no-op today — real corpora had zero sidechains). When subagent sidechains DO appear, real debugging may live inside them.

## Goal
When a sidechain carries hypothesis-rejection / correction signal, preserve its convergence (not just an outcome line) so the Dead-ends extractor can mine it.

## Implementation Notes
- Detect signal-bearing sidechains (cue phrases, errors, corrections) vs routine ones.
- Untestable against current real data (no True isSidechain found) — needs a real multi-subagent session.

## Affects
- skills/transcript-parse/ (assemble/parselib)
- skills/handoff/prepass.sh

## Effort
Medium

---

*Added: 2026-06-05*
