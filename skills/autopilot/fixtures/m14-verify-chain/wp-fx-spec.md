# Fixture spec (m14-verify-chain, WP 1-15 T10, AC F)

## Acceptance criteria

### wp-fx

- **A.** the settings page renders the new field on load
  Verify: bash skills/fx/test-a.sh
- **B.** the settings page persists the new field to the backing store
  Verify: bash skills/fx/test-b.sh
- **C.** the settings page validates the new field before submit
  Verify: bash skills/fx/test-c.sh
- **D.** the settings page shows an error message on an invalid value
  Verify: bash skills/fx/test-d.sh
- **E.** the settings page clears the error message once the value is fixed
  Verify: bash skills/fx/test-e.sh
- **F.** the settings page disables submit while the field is invalid
  Verify: bash skills/fx/test-f.sh
- **G.** the settings page logs the change to the audit trail
  Verify: bash skills/fx/test-g.sh
- **H.** the settings page keeps the prior value when the request fails
- **I.** [process] the full test suite exits 0 and every CI gate passes
