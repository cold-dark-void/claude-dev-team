# Fixture spec (m14-suite-hygiene bite test)

## Acceptance criteria

### fx-hygiene

- **A.** a fixture AC whose Verify file does not call hermetic_init
  Verify: bash skills/fx/test-nonhermetic.sh

### fx-livecouncil

- **A.** a fixture AC whose Verify file is otherwise hermetic but spawns council live (positive control)
  Verify: bash skills/fx/test-livecouncil.sh
