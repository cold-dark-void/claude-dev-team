# SPEC-030 broken test-script fixture

`broken-test.sh` matches the `*-test.sh` Script pattern and fails
`bash -n` (unclosed `if`) -> FAIL naming the file. Proves a test
script is discovered and parse-checked like any other Script, never
invoked (its body mutates state).
