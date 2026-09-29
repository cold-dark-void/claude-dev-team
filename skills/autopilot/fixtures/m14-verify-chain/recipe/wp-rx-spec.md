# Fixture spec (m14-verify-chain, WP 1-16 T2, AC E)

## Acceptance criteria

### wp-rx

- **A.** the loader validates the `schema.json` config against Case 2 of the
  parser and applies rule (3) before it writes the result
  Verify: bash skills/fx/test-rx-a.sh
- **B.** the writer commits the change recorded at skills/fx/test-rx-b.sh:5
  before it logs the outcome
  Verify: bash skills/fx/test-rx-b.sh
- **C.** the merger checks AC A before it appends to `merge.log`
  Verify: bash skills/fx/test-rx-c.sh
