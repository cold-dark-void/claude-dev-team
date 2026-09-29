# Fixture: two subsections sharing bullet id A (WP 1-16 AC C)

### wp-aa-fixture-one

- **A.** First subsection's AC A bullet text, used only to prove the
  quote command targets the SECOND occurrence, not this one.
  Verify: bash skills/fx/test-a1.sh
- **B.** An unrelated bullet that must never appear in the quote output.

### wp-bb-fixture-two

- **A.** Second subsection's AC A bullet is the true target: its own
  two lines of continuation text belong in the quote output and
  nothing from the next bullet.
  Verify: bash skills/fx/test-a2.sh
- **B.** Another unrelated bullet, also excluded from the quote output.
