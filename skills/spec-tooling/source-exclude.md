<!--
Canonical spec-code-alignment source-exclude set — what counts as PRODUCT source
that spec→code alignment greps (SPEC-008 "Source Exclusions (code alignment)").
Single source; included byte-identical into the four alignment consumers via
<!-- include: skills/spec-tooling/source-exclude.md agent=spec --> markers,
drift-gated at /release. Cite SPEC-008 (the alignment contract).

Included into (consumers; region count drifts as /spec consolidates):
- commands/check-specs.md  ×2  (audit Phase-2 grep + validate-mode grep)
- skills/spec-tooling/SKILL.md ×2 (reflect Phase-1c inventory + Phase-4 alignment grep)
- skills/reflect-specs/SKILL.md ×2 (legacy until Task-7 stub; same partial)
- commands/update-spec.md  ×1  (code-impact grep for ADDED/MODIFIED requirements)
NOTE: /spec generate (ex-/generate-specs) is NOT a consumer — its GENERATION-scope
scan is a DISTINCT exclusion (it skips skills/ + commands/); it cites SPEC-008 but
is not this partial.

Editing notes (this block is stripped by sync-includes.py expand() — it drops
everything up to and including the first lone `-->` line):
- The body below is the byte-identical region every alignment consumer includes.
- There is NO `<AGENT>` token — `agent=spec` is a no-op sentinel (expand() substitutes
  `<AGENT>` only; with none present the region is identical for every consumer).
- Do NOT path-exclude `skills/` or `commands/`: the `*.md` extension exclude already
  drops the plugin's own SKILL.md/command.md prose self-match, while real implementation
  under `skills/*.sh` (and `.go`/`.ts`/etc. in any consumer project) stays visible to
  code-alignment. Path-excluding those dirs would hide this repo's genuine `.sh` logic.

LEAK-SAFE FENCE CONTRACT (P1-1A/P1-1B hazard guard):
- The exclude set below is wrapped in a ```text … ``` fence so each consumer can paste it
  onto its OWN standalone lines. The include markers each consumer adds sit OUTSIDE that
  fence — so `<!-- include -->` / `<!-- /include -->` NEVER land inside fenced content a
  reader/LLM might treat as literal, and never leak into any produced artifact.
- The two lines below ARE the exact exclude semantics each consumer already expresses inline
  ("exclude paths: …; exclude file extensions: …"); lift the inline fragment onto its own
  lines and wrap with the include markers (markers outside the fence) so the region is
  byte-identical everywhere and drift-gated.
-->
```text
Exclude paths:      specs/  .claude/  node_modules/  dist/  build/  target/  vendor/  .git/
Exclude extensions: *.md  *.txt  *.json  *.yaml  *.yml  *.toml  *.lock  *.sum  *.pb.go  *_gen.*  *_generated.*
```
