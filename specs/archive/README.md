# specs/archive/

Retired specifications live here (CDT-294). A spec moves here only after its
Status line is `DEPRECATED`.

Convention:

- Keep the file name and the `**Status**: DEPRECATED` line unchanged. Do not
  edit the body further; the file is a frozen record.
- Keep the spec's row in `specs/TDD.md`. Point the row's Coverage note at this
  directory. Do not delete history rows that mention the spec.
- `tools/spec-lint.sh` skips this directory, like `fixtures/`. A file here is
  captured history, not a linted contract.
- A live spec that supersedes an archived one links to the archived path with
  a plain path reference (see SPEC-014 § See also).
