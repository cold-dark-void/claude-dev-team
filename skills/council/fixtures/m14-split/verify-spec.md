# Fixture spec (m14-split, T3, Verify)

## Acceptance criteria

### wp-verify-split

- **A.** the widget renders the new field on the settings page
  Verify: bash test-stub.sh
- **B.** the widget persists the new field to the backing store
- **C.** [process] the full test runner exits 0 and every CI gate passes
