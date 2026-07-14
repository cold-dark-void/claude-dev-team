# COUNCIL-002 — `/council --from-retro <anchor-id>` scope

**Status**: COMPLETED — shipped v0.65.0 (CDV-212)

## Problem

`/retro` (post-COUNCIL-001) classifies fabrication anchors and prints `Consider: /council --from-retro <anchor-id>` hints at completion. The hint is a forward-compat advertisement — the actual command currently fails loudly with the COUNCIL-002 deferral message. Users see the hint, try the command, get a wall.

## Goal

Resolve a fabrication anchor ID into a structured claim, then run the standard council pipeline against it. The retro-subagent already produces a deterministic `anchor_id = sha1(session_id + ":" + turn_id + ":" + claim[:50])[:16]`, but COUNCIL-001 doesn't persist these anywhere — they're emitted in the retro report and lost. Two design choices:

(a) Persist anchors at retro time. retro-subagent writes `.claude/retro/anchors/<anchor_id>.json` containing `{anchor_id, session_id, turn_id, fabricated_claim_text, evidence_for_fabrication, source_jsonl_path}`. `/council --from-retro <anchor_id>` reads the file and runs Phase 2-5 with the claim text as scope.

(b) Lookup anchors at council time. `/council --from-retro <anchor_id>` scans recent `~/.claude/projects/<encoded>/*.jsonl` files for the matching anchor, recomputing the hash. Slower but no new storage.

Recommend (a) — explicit storage path, faster, idempotent across retro runs because the hash is deterministic.

## Implementation Notes

- Add `.claude/retro/anchors/` writes in `skills/retro-subagent/SKILL.md` and the parsing pass in `commands/retro.md`
- Add `--scope from-retro --scope-arg <anchor_id>` handling in `engine.sh` preflight: read the anchor file, hand the claim_text to Phase 1 (which skips extraction since the claim is already isolated)
- Add `.claude/retro/` to `.gitignore`
- Update SPEC-012 with the new anchor storage path (small delta)
- Update SPEC-013 deferred-scope MUSTs once the scope is live

## Notes

Source: deferred from COUNCIL-001 per locked decision 1 + locked decision 8 (deferred scopes fail loudly). The hint plumbing already exists in v0.18.0 — only the consumer side needs implementation.

---

*Added: 2026-04-09*

*Closed: 2026-07-14*
