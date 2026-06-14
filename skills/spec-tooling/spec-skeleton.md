<!--
Canonical spec-file skeleton — the 9 required sections SPEC-008 mandates.
Single source; included into /generate-specs and /create-spec via
<!-- include: skills/spec-tooling/spec-skeleton.md agent=spec --> markers,
drift-gated at /release. Cite SPEC-008 (format contract) + SPEC-004.

Editing notes (this block is stripped by sync-includes.py expand() — it drops
everything up to and including the first lone `-->` line):
- The body below is the byte-identical region that every emitter includes.
- `**Status**: <STATUS>` keeps the literal `<STATUS>` token: sync-includes.py only
  substitutes `<AGENT>`, never `<STATUS>`, so the token survives expansion byte-identically
  across emitters (drift-checkable). Each emitter's OWN prose (added outside the markers in
  fan-out) tells the LLM to replace `<STATUS>` with INFERRED (/generate-specs) or DRAFT (/create-spec).
- Do NOT add an `<AGENT>` token here — `agent=spec` is a no-op sentinel.
- Keep placeholders honest (no TBD/foo — /check-specs Content-Quality flags those).

FAN-OUT PLACEMENT CONTRACT (read before adding markers):
- This region is the CONTIGUOUS 9 required sections, ending in `## Version History`.
  Wrap it byte-for-byte: marker line ABOVE `# <PREFIX>-<NNN>:` and `<!-- /include -->`
  line BELOW the final VH table row. Nothing required goes outside it.
- Emitter EXTRAS live entirely AFTER the closing `<!-- /include -->` marker, never inside:
    * /generate-specs: `**Covers**: <files>` line, then `## SHOULD`, `## Open Questions`,
      `## Cross-references` — appended after `<!-- /include -->`. (VH is therefore NOT the
      literal last section in a generated spec; this is ALLOWED — SPEC-008 mandates section
      PRESENCE + spelling + heading-level, NOT order. /check-specs Phase 1 passes.)
    * /create-spec: emits NO extras; its `---` separator style stays OUTSIDE the markers
      (above/below), so the included bytes match /generate-specs exactly.
- The `**Covers**:` line is NOT one of the 9 required sections (check-specs does not check it).
  It is emitter metadata; /generate-specs emits it as an extra after the region.

LEAK-SAFE FENCE CONTRACT (P1-1B hazard guard):
- The 9-section body below is wrapped in a ```markdown … ``` fence so it travels INSIDE the
  emitter's own ```markdown template block. The include markers each emitter adds sit OUTSIDE
  that fence — so `<!-- include -->` / `<!-- /include -->` NEVER appear in the template body the
  LLM copies into a real spec file (SPEC-005 marker-free MUST). The fence also stops the body's
  `##` headings from polluting an emitter's outline.
-->
```markdown
# <PREFIX>-<NNN>: <Title>

**Status**: <STATUS>
**Category**: core
**Created**: <YYYY-MM-DD>

## Overview

<One paragraph: what behavior this spec governs and why it exists.>

## MUST

- MUST <one concrete, testable requirement>

## Test

- [ ] <one concrete check verifying a MUST requirement above>

## Validation

- [ ] Spec reviewed and promoted to ACTIVE

## Version History

| Date | Change |
|------|--------|
| <YYYY-MM-DD> | Initial version |
```
