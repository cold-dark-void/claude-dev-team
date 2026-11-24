# Fixture spec (verify-span-coverage, CDT-605)

## Acceptance criteria

### cdt605-span

- **A.** `engine.sh span-audit` exits 0 when every token of the quote — the
  spans `span-audit` and `raw "blob"`, the locators
  skills/council/engine.sh:85 and skills/council/engine-util.sh:20, plus the
  run Case 7 and the reference AC B — has a bundle line that holds it.
  Verify: bash skills/council/test-span-fixture.sh
- **B.** `engine.sh span-brief` prints the brief block for Case 8 only.
  Verify: bash skills/council/test-span-fixture.sh

### cdt605-false-positive

- **A.** the audit ignores the host:12 endpoint, the 14:32 clock and the
  v2:1 shorthand, so no locator token is extracted from this AC.
  Verify: bash skills/council/test-span-fixture.sh

---

## Trailing section

Not part of the AC section.
