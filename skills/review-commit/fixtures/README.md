# review-commit snapshot fixtures

Inputs for the Task 15 end-to-end snapshot test over `/review-commit` in
diff-mode preset.

## Files

- `canned-diff.patch` — a small representative staged diff (≈25 lines)
  covering multiple specialist concerns in a single function:
  hardcoded secret (security), SQL injection (security), auth bypass
  (logic + security), PII in logs (compliance), swallowed DB error
  (design), magic HTTP status (nitpick). Intentionally terrible code —
  the goal is to exercise every section of the Step 6 rendered review.
- `expected-output.txt` — the **structural** expected output of
  `/review-commit` against `canned-diff.patch`, hand-written in the
  legacy Step 6 / Step 8 format.

## Snapshot test constraint (read before comparing)

The expected output is **hand-authored**, not captured from a real
pre-refactor run. LLM output is non-deterministic — exact phrasing,
confidence scores, and the number of nitpick findings will vary from run
to run.

**Task 15 MUST compare structurally, not literally.** The snapshot test
should assert:

1. Every `## <Section Heading>` present in `expected-output.txt` is
   present in the actual output, in the same order, with identical
   heading text (including the `[confidence 80-94]` / `[confidence 95-100]`
   bracket annotations).
2. The `## Overall Assessment` section ends with one of
   `APPROVE | REQUEST CHANGES | NEEDS DISCUSSION`.
3. The `Review stats:` line matches the pattern
   `Review stats: \d+ findings from 5 agents, \d+ passed confidence filter \(≥80\), \d+ discarded\.`.
4. The `Action Items:` summary line matches the pattern
   `Action Items: \d+ BLOCKERs, \d+ (COMPLIANCE, \d+ )?DESIGN, \d+ NITPICK — (commit blocked|commit proceeded)`.
5. Every `- [ ]` action item line starts with one of
   `BLOCKER | COMPLIANCE | DESIGN | NITPICK`, carries a backticked
   `file:line`, and ends with `[confidence: N]`.
6. For this specific canned diff: at least one BLOCKER is present and
   the gate status is `commit blocked` (the diff contains a hardcoded
   secret and SQL injection — no sane specialist pipeline would
   approve it).

Do NOT diff `expected-output.txt` byte-for-byte against actual output —
that test will be flaky forever.
