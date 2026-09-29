# Fixture spec (m14-verify-chain, WP 1-16 T2 review fix M7/gap4): two
# subsections sharing the AC id "A" at different lines, to prove the
# conformance quote must anchor on the split's own .line for the ticket
# under audit, not just any "- **A.**" bullet in the file.

## Acceptance criteria

### wp-other

- **A.** this bullet belongs to a different ticket and must never be quoted
  for wp-rx
  Verify: bash skills/fx/test-other-a.sh

### wp-rx

- **A.** the loader validates the `schema.json` config against Case 2 of the
  parser and applies rule (3) before it writes the result
  Verify: bash skills/fx/test-rx-a.sh
- **B.** the writer commits the change recorded at skills/fx/test-rx-b.sh:5
  before it logs the outcome
  Verify: bash skills/fx/test-rx-b.sh
- **C.** the merger checks AC A before it appends to `merge.log`
  Verify: bash skills/fx/test-rx-c.sh
