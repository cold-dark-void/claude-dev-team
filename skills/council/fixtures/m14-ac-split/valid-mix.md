# Fixture spec (m14-ac-split, T1)

## Acceptance criteria

Format and rules: M14(g) and M14(h).

### wp-other-ticket

- **A.** an AC that belongs to a different ticket and MUST NOT be picked
- **B.** [process] the test runner exits 0

### wp-valid-mix

- **A.** the diff adds a widget
  - continuation line, indented by two spaces
  - a second continuation line
- **B.** [process] `bash tools/run-all-tests.sh` exits 0 and every CI gate passes
- **C.** the widget renders on the settings page

---

## Trailing section

Not part of the AC section.
