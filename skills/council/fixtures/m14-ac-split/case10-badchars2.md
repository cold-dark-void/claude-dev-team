# Fixture spec (m14-ac-split, T2, case 10 -- more disallowed characters)

## Acceptance criteria

### wp-case10-squote

- **A.** the diff adds a widget
  Verify: bash test-widget.sh 'evil'

### wp-case10-backslash

- **A.** the diff adds a widget
  Verify: bash test-widget.sh\evil

### wp-case10-star

- **A.** the diff adds a widget
  Verify: bash test-widget.sh *

### wp-case10-tilde

- **A.** the diff adds a widget
  Verify: bash test-widget.sh ~evil

### wp-case10-doublespace

- **A.** the diff adds a widget
  Verify: bash test-widget.sh  extra-arg
