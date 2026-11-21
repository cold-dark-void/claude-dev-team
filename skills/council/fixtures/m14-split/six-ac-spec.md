# Fixture spec (m14-split, CDT-611 ceiling clamp)

## Acceptance criteria

### wp-six-ac

- **A.** the widget renders the new field on the settings page
  Verify: bash test-stub.sh
- **B.** the widget persists the new field to the backing store
  Verify: bash test-stub.sh
- **C.** the widget validates the field on input
  Verify: bash test-stub.sh
- **D.** the widget clears the field on reset
  Verify: bash test-stub.sh
- **E.** the widget exports the field in the API payload
  Verify: bash test-stub.sh
- **F.** the widget logs the field's lifecycle events
  Verify: bash test-stub.sh
- **G.** [process] the full test runner exits 0 and every CI gate passes
