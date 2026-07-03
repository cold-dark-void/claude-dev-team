# Fix retro-gate S3 false positives on draft-then-polish authoring

**Status**: PENDING

## Problem

The S3 "edit loop" signal fires on Write-then-Edit sequences against files the assistant created in the same session. On session `d46888fd` (SPEC-020 design session) it fired ×2 and pushed the gate to exactly threshold (5.0) with zero real friction — the edits were self-review nits on a freshly written spec + plan, with no tool errors and no user rejections. Cost: a full Phase-2 deep-read spawn on a smooth session.

## Goal

Exclude edits to a file created by Write in the same session when no tool errors or user rejections intervene (draft-then-polish is not an edit loop). S3 keeps firing on genuine edit loops (repeated edits to pre-existing files, or edit sequences interleaved with errors/rejections).

## Implementation Notes

- Change is in `skills/retro-gate/gate.sh` S3 scoring; SPEC-012 may need a matching MUST/threshold note.
- Bite-test both directions: a synthetic draft-then-polish session must NOT fire S3; a genuine edit-loop fixture must still fire.

## Affects

`skills/retro-gate/gate.sh`, `specs/core/SPEC-012-session-retrospective.md`.

## Effort

S

## Notes

Source: /retro run 2026-07-03 (deep-read of session d46888fd, confidence 0.75, 3 citations). Refines the RETRO-001 dogfood finding "S1-S4 accurate": S3 is accurate on real loops but over-fires on authoring polish.

---

*Added: 2026-07-03*
